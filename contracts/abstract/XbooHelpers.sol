pragma solidity ^0.8.0;

import "./ReaperBaseStrategy.sol";
import "../interfaces/IAceLab.sol";
import "../interfaces/IBooMirrorWorld.sol";
import "../interfaces/IUniswapRouterETH.sol";
import "../interfaces/IPaymentRouter.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SignedSafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

abstract contract XbooHelpers is ReaperBaseStrategyv3{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IBooMirrorWorld;
    using SafeMathUpgradeable for uint256;
    using SignedSafeMathUpgradeable for int256;
    /**
     * @dev Adds a pool from the {aceLab} contract to be actively used to yield.
     * _poolRewardToWftmPath can be empty if the paths are standard rewardToken -> wftm
     */

    /**
     * @dev Tokens Used:
     * {wftm} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {xToken} - Token generated by staking our funds. Also used to stake in secondary pools.
     * {stakingToken} - Token that the strategy maximizes.
     */
    address public constant wftm = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    IBooMirrorWorld public constant xToken =
        IBooMirrorWorld(0xa48d959AE2E88f1dAA7D5F611E01908106dE7598); // xBoo
    IERC20Upgradeable public constant stakingToken =
        IERC20Upgradeable(0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE); // Boo

    /**
     * @dev Third Party Contracts:
     * {uniRouter} - the uniRouter for target DEX
     * {aceLab} - Address to AceLab, the SpookySwap contract to stake xToken
     */
    address public constant uniRouter =
        0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    address public constant currentAceLab = 0x399D73bB7c83a011cD85DF2a3CdF997ED3B3439f;
    address public constant currentMagicats = 0x2aB5C606a5AA2352f8072B9e2E8A213033e2c4c9;

    address public magicatsHandler;
    
    address public aceLab;
    address public Magicats;

    /**
     * @dev Routes we take to swap tokens
     * {wftmToStakingTokenPaths} - Route we take to get from {wftm} into {stakingToken}.
     * {poolRewardToWftmPaths} - Routes for each pool to get from {pool reward token} into {wftm}.
     */
    address[] public wftmToStakingTokenPaths;
    mapping(uint256 => address[]) public poolRewardToWftmPaths;

    /**
     * @dev Variables for pool selection
     * {currentPoolId} - Pool id for the the current pool the strategy deposits xToken into
     * {currentlyUsedPools} - A list of all pool ids currently being used by the strategy
     * {poolYield} - The estimated yield in wftm for each pool over the next 1 day
     * {hasAllocatedToPool} - If a given pool id has been deposited into already for a harvest cycle
     * {maxPoolDilutionFactor} - The factor that determines what % of a pools total TVL can be deposited (to avoid dilution)
     * In Basis points so 10000 = 100%, can be any % of the pool to deposit in
     * {maxNrOfPools} - The maximum amount of pools the strategy can use
     */
    uint256 public currentPoolId;
    uint256[] public currentlyUsedPools;
    mapping(uint256 => uint256) public poolYield;
    mapping(uint256 => bool) public hasAllocatedToPool;
    uint256 public maxPoolDilutionFactor;
    uint256 public maxNrOfPools;

    /**
     * @dev Variables for pool selection
     * {totalPoolBalance} - The total amount of xToken currently deposited into pools
     * {poolxTokenBalance} - The amount of xToken deposited into each pool
     */
    uint256 public totalPoolBalance;
    mapping(uint256 => uint256) public poolxTokenBalance;

    /**
     * @dev Fee variables
     * {useSecurityFee} - If security fee should be applied on withdraw, controlled by the fee moderator
     */
    bool public useSecurityFee;

    /**
     * {UpdatedStrategist} Event that is fired each time the strategist role is updated.
     */
    event UpdatedStrategist(address newStrategist);



    function __XbooHelpers_init(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address[] memory _multisigRoles
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists, _multisigRoles);
        useSecurityFee = false;

        aceLab = currentAceLab;
        Magicats = currentMagicats;
        currentPoolId = 0;
        maxPoolDilutionFactor = 10000;
        maxNrOfPools = 15;
        totalPoolBalance = 0;
        wftmToStakingTokenPaths = [wftm, address(stakingToken)];

        _giveAllowances();

    }



    function addUsedPool(
        uint256 _poolId,
        address[] memory _poolRewardToWftmPath
    ) external {
        _atLeastRole(STRATEGIST);
        require(currentlyUsedPools.length < maxNrOfPools, "Max pools reached");
        require(
            _poolRewardToWftmPath.length >= 2 ||
                (_poolRewardToWftmPath.length == 1 &&
                    _poolRewardToWftmPath[0] == wftm),
            "Must have reward paths"
        );
        currentlyUsedPools.push(_poolId);
        poolRewardToWftmPaths[_poolId] = _poolRewardToWftmPath;

        address poolRewardToken = _poolRewardToWftmPath[0];
        if (poolRewardToken != wftm) {
            IERC20Upgradeable(poolRewardToken).safeApprove(uniRouter, type(uint256).max);
        }
    }


        /**
     * @dev Gives max allowance of {stakingToken} for the {xToken} contract,
     * {xToken} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _giveAllowances() internal {
        // Give xToken permission to use stakingToken
        stakingToken.safeApprove(address(xToken), 0);
        stakingToken.safeApprove(address(xToken), type(uint256).max);
        // Give xToken contract permission to stake xToken
        xToken.safeApprove(aceLab, 0);
        xToken.safeApprove(aceLab, type(uint256).max);
        // Give uniRouter permission to swap wftm to stakingToken
        IERC20Upgradeable(wftm).safeApprove(uniRouter, 0);
        IERC20Upgradeable(wftm).safeApprove(uniRouter, type(uint256).max);
        _givePoolAllowances();
    }

    /**
     * @dev Removes all allowance of {stakingToken} for the {xToken} contract,
     * {xToken} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _removeAllowances() internal {
        // Remove xToken permission to use stakingToken
        stakingToken.safeApprove(address(xToken), 0);
        // Remove xToken contract permission to stake xToken
        xToken.safeApprove(aceLab, 0);
        // Remove uniRouter permission to swap wftm to stakingToken
        IERC20Upgradeable(wftm).safeApprove(uniRouter, 0);
        _removePoolAllowances();
    }

        /**
     * @dev Gives max allowance to all pool rewards for the {uniRouter}.
     */
    function _givePoolAllowances() internal {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            IERC20Upgradeable rewardToken = IERC20Upgradeable(
                poolRewardToWftmPaths[currentlyUsedPools[index]][0]
            );
            rewardToken.safeApprove(uniRouter, 0);
            rewardToken.safeApprove(uniRouter, type(uint256).max);
        }
    }

    /**
     * @dev Removes all allowance to all pool rewards for the {uniRouter}.
     */
    function _removePoolAllowances() internal {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            IERC20Upgradeable rewardToken = IERC20Upgradeable(
                poolRewardToWftmPaths[currentlyUsedPools[index]][0]
            );
            rewardToken.safeApprove(uniRouter, 0);
        }
    }

    /**
     * @dev updates the {maxPoolDilutionFactor} set in basis points so 10000 = 100%
     */
    function updateMaxPoolDilutionFactor(uint256 _maxPoolDilutionFactor)
        external
    {
        _atLeastRole(STRATEGIST);
        require(_maxPoolDilutionFactor != 0, "!=0");
        maxPoolDilutionFactor = _maxPoolDilutionFactor;
    }

    /**
     * @dev updates the {maxNrOfPools}
     */
    function updateMaxNrOfPools(uint256 _maxNrOfPools) external {
        require(maxNrOfPools != 0, "!=0");
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not authorized");
        maxNrOfPools = _maxNrOfPools;
    }



    /**
     * @dev Removes a pool that will no longer be used.
     */
    function removeUsedPool(uint256 _poolIndex) public {
        _atLeastRole(STRATEGIST);
        uint256 poolId = currentlyUsedPools[_poolIndex];
        IERC20Upgradeable(poolRewardToWftmPaths[poolId][0]).safeApprove(uniRouter, 0);
        uint256 balance = poolxTokenBalance[poolId];
        _aceLabWithdraw(poolId, balance);
        uint256 lastPoolIndex = currentlyUsedPools.length - 1;
        uint256 lastPoolId = currentlyUsedPools[lastPoolIndex];
        currentlyUsedPools[_poolIndex] = lastPoolId;
        currentlyUsedPools.pop();

        if (currentPoolId == poolId) {
            currentPoolId = currentlyUsedPools[0];
        }
        _aceLabDeposit(currentPoolId, balance);
    }
    function updateMagicatsHandler(address handler) external{
        magicatsHandler = handler;
    }

    /**
     * @dev Function to withdraw from AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabWithdraw(uint256 _poolId, uint256 _xTokenAmount) internal {
        totalPoolBalance = totalPoolBalance.sub(_xTokenAmount);
        poolxTokenBalance[_poolId] = poolxTokenBalance[_poolId].sub(
            _xTokenAmount
        );
        IAceLab(aceLab).withdraw(_poolId, _xTokenAmount);
    }

    /**
     * @dev Function to deposit into AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabDeposit(uint256 _poolId, uint256 _xTokenAmount) internal {
        totalPoolBalance = totalPoolBalance.add(_xTokenAmount);
        poolxTokenBalance[_poolId] = poolxTokenBalance[_poolId].add(
            _xTokenAmount
        );
        IAceLab(aceLab).deposit(_poolId, _xTokenAmount);
    }

}