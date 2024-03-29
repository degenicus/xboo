// SPDX-License-Identifier: AGPLv3

pragma solidity 0.8.9;

import "./abstract/ReaperBaseStrategy.sol";
import "./interfaces/IAceLab.sol";
import "./interfaces/IBooMirrorWorld.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "./interfaces/IMagicatsHandler.sol";
import "./interfaces/IExternalHandler.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

/**
 * @dev This is a strategy to stake Boo into XBOO, and then stake XBOO in different pools to collect more rewards
 * The strategy will compound the pool rewards into Boo which will be deposited into the strategy for more yield.
 */
contract ReaperAutoCompoundXBoov2 is ReaperBaseStrategyv3, IERC721ReceiverUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IBooMirrorWorld;

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {XBOO} - Token generated by staking our funds. Also used to stake in secondary pools.
     * {Boo} - Token that the strategy maximizes.
     */
    address public constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address public constant USDC = 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75;
    IBooMirrorWorld public constant XBOO = IBooMirrorWorld(0xa48d959AE2E88f1dAA7D5F611E01908106dE7598); // XBOO
    IERC20Upgradeable public constant BOO = IERC20Upgradeable(0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE); // BOO

    /**
     * @dev Third Party Contracts:
     * {UNIROUTER} - the UNIROUTER for target DEX
     * {MAGICATS} - NFT collection that improves staking rewards
     * {aceLab} - Address to AceLab, the SpookySwap contract to stake XBOO
     * {magicatsHandler} - NFT vault for magicats that allows for management + deposit/withdraw of magicatNFTs
     */
    address public constant UNIROUTER = 0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    address public constant MAGICATS = 0x2aB5C606a5AA2352f8072B9e2E8A213033e2c4c9;
    address public magicatsHandler;
    address public aceLab;

    /**
     * @dev Routes we take to swap tokens
     * {WFTMToBOOPath} - Route we take to get from {WFTM} into {BOO}.
     * {WFTMToUSDCPath} - Route we take to get from {WFTM} into {USDC}.
     * {poolRewardToWFTMPaths} - Routes for each pool to get from {pool reward token} into {WFTM}.
     */
    address[] public WFTMToBOOPath;
    address[] public WFTMToUSDCPath;
    mapping(uint256 => address[]) public poolRewardToWFTMPaths;

    /**
     * @dev Variables for pool selection
     * {currentPoolId} - Pool id for the the current pool the strategy deposits XBOO into
     */
    uint256 public currentPoolId;

    /**
     * @dev Variables for pool selection
     * {totalPoolBalance} - The total amount of XBOO currently deposited into pools
     * {poolXBOOBalance} - The amount of XBOO deposited into each pool
     * {depositedPools} - Enumerable set containing IDs of all the pools we currently have funds in
     */
    uint256 public totalPoolBalance;
    mapping(uint256 => uint256) public poolXBOOBalance;
    EnumerableSetUpgradeable.UintSet private depositedPools;

    /***
     * {accCatDebt} - mapping of poolID -> accumulated catDebt between harvest.
     *                Accounted for each time catDebt is reset (deposit/withdraw/harvest).
     * {catProvisionFee} - amount of boosted harvest diverted to magicatsHandler
     */
    mapping(uint256 => uint256) public accCatDebt;
    uint256 public catProvisionFee;

    struct RewardHandler {
        bool requiresSpecialHandling;
        address handler;
    }
    //mapping of poolIds to a struct that specifies if the token requires special preperation to turn into WFTM (ex. xTarot)
    //and the address of the contract that can handle it according the pre-set API
    mapping(uint256 => RewardHandler) public idToSpecialHandler;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address[] memory _multisigRoles
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists, _multisigRoles);

        aceLab = 0x399D73bB7c83a011cD85DF2a3CdF997ED3B3439f;

        currentPoolId = 5;
        totalPoolBalance = 0;
        WFTMToBOOPath = [WFTM, address(BOO)];
        WFTMToUSDCPath = [WFTM, USDC];
        catProvisionFee = 5000;

        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {BOO} into XBOO (BOOMirrorWorld) to farm {XBOO} and finally,
     * XBOO is deposited into other pools to earn additional rewards
     */
    function _deposit() internal override whenNotPaused {
        uint256 booBalance = BOO.balanceOf(address(this));
        if (booBalance != 0) {
            XBOO.enter(booBalance);
        }

        _aceLabDeposit(currentPoolId, XBOO.balanceOf(address(this)));
    }

    /**
     * @dev Function to deposit into AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabDeposit(uint256 _poolId, uint256 _XBOOAmount) internal {
        totalPoolBalance += _XBOOAmount;
        poolXBOOBalance[_poolId] += _XBOOAmount;
        if (_XBOOAmount != 0 && !depositedPools.contains(_poolId)) {
            depositedPools.add(_poolId);
        }
        _writeCatDebt(_poolId);
        IAceLab(aceLab).deposit(_poolId, _XBOOAmount);
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {BOO} from the AceLab pools.
     * The available {BOO} minus fees is returned to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        uint256 booBalance = BOO.balanceOf(address(this));

        if (booBalance < _amount) {
            uint256 xBooToWithdraw = XBOO.BOOForxBOO(_amount - booBalance);
            uint256[] memory depositedPoolIDs = depositedPools.values();
            uint256 depositPoolsLength = depositedPoolIDs.length;

            uint256 withdrawnAmount = 0;
            uint256 amountToWithdraw;
            for (uint256 i = 0; i < depositPoolsLength; i = _uncheckedInc(i)) {
                uint256 currentDepositedPoolId = depositedPoolIDs[i];
                amountToWithdraw = _getMin(poolXBOOBalance[currentDepositedPoolId], _amount - withdrawnAmount);
                _aceLabWithdraw(currentDepositedPoolId, amountToWithdraw);
                withdrawnAmount += amountToWithdraw;

                if (withdrawnAmount >= xBooToWithdraw) {
                    break;
                }
            }

            XBOO.leave(xBooToWithdraw);

            booBalance = BOO.balanceOf(address(this));
            if (booBalance < _amount) {
                require(_amount - booBalance <= 10);
                _amount = booBalance;
            }
        }

        BOO.safeTransfer(vault, _amount);
    }

    /**
     * @dev Function to withdraw from AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabWithdraw(uint256 _poolId, uint256 _XBOOAmount) internal {
        totalPoolBalance -= _XBOOAmount;
        poolXBOOBalance[_poolId] -= _XBOOAmount;
        if (poolXBOOBalance[_poolId] == 0 && depositedPools.contains(_poolId)) {
            depositedPools.remove(_poolId);
        }
        _writeCatDebt(_poolId);
        IAceLab(aceLab).withdraw(_poolId, _XBOOAmount);
    }

    /**
     * @dev Function to set Allocations of XBOO in acelab, called by Keepers or strategists to maintain maximal APR
     * {withdrawPoolIds} - Pool Ids that the strategy should reduce the balance of
     * {withdrawAmounts} - corresponding to the withdrawPoolIds, the amount those pIds should be reduced
     * {depositPoolIds} - Pool Ids that the strategy should increase the balance of
     * {depositAmounts} - corresponding to the depositPoolIds, the amount those pIds should be increased
     */
    function setXBooAllocations(
        uint256[] calldata withdrawPoolIds,
        uint256[] calldata withdrawAmounts,
        uint256[] calldata depositPoolIds,
        uint256[] calldata depositAmounts
    ) external {
        _atLeastRole(KEEPER);
        uint256 depositPoolsLength = depositPoolIds.length;
        uint256 withdrawPoolsLength = withdrawPoolIds.length;

        for (uint256 i = 0; i < withdrawPoolsLength; i = _uncheckedInc(i)) {
            _aceLabWithdraw(withdrawPoolIds[i], withdrawAmounts[i]);
        }

        for (uint256 i = 0; i < depositPoolsLength; i = _uncheckedInc(i)) {
            uint256 XBOOAvailable = IERC20Upgradeable(XBOO).balanceOf(address(this));
            if (XBOOAvailable == 0) {
                return;
            }
            uint256 depositAmount = _getMin(XBOOAvailable, depositAmounts[i]);
            _aceLabDeposit(depositPoolIds[i], depositAmount);
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the AceLab pools and estimated the current yield for each pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {WFTM} token for {BOO} which is deposited into {XBOO}
     * 4. It distributes the XBOO using a yield optimization algorithm into various pools.
     */
    function _harvestCore() internal override returns (uint256 callerFee) {
        _claimAllRewards();
        uint256 catBoostPercentage = _processRewards();
        callerFee = _chargeFees();
        _swapWFTMToBOO();
        if (magicatsHandler != address(0) && catBoostPercentage != 0) {
            _payMagicatDepositors(catBoostPercentage);
            IMagicatsHandler(magicatsHandler).processRewards();
        }
        _enterXBOO();
        _aceLabDeposit(currentPoolId, XBOO.balanceOf(address(this)));
    }

    function _claimAllRewards() internal {
        uint256[] memory depositedPoolIDs = depositedPools.values();
        uint256 depositPoolsLength = depositedPoolIDs.length;
        for (uint256 i = 0; i < depositPoolsLength; i = _uncheckedInc(i)) {
            _aceLabWithdraw(depositedPoolIDs[i], 0);
        }
    }

    /**
     * @notice Converts all reward tokens in WFTM and calculates the XBOO % that
     *         was boosted by the cats.
     */
    function _processRewards() internal returns (uint256) {
        uint256 depositPoolsLength = depositedPools.length();
        uint256 tokenBal;
        address _handler;
        uint256 WFTMBalBefore;
        uint256 WFTMBalAfter;
        uint256 catBoostPercent;
        uint256 catBoostWFTM;
        uint256 catBoostTotal;
        uint256 totalHarvest;
        address rewardToken;
        uint256 activeIndex;
        for (uint256 index = 0; index < depositPoolsLength; index = _uncheckedInc(index)) {
            activeIndex = depositedPools.at(index);
            rewardToken = address(IAceLab(aceLab).poolInfo(activeIndex).RewardToken);
            tokenBal = IERC20Upgradeable(rewardToken).balanceOf(address(this));
            if (tokenBal != 0) {
                WFTMBalBefore = IERC20Upgradeable(WFTM).balanceOf(address(this));

                //leave is pretty standard for xTokens if it does not have leave we will need an external handler
                try IBooMirrorWorld(rewardToken).leave(tokenBal) {} catch {}

                if (accCatDebt[activeIndex] != 0) {
                    catBoostPercent = (accCatDebt[activeIndex] * PERCENT_DIVISOR) / tokenBal;
                } else {
                    catBoostPercent = 0;
                }

                _handler = _requireExternalHandling(activeIndex);
                if (_handler == address(this)) {
                    _swapRewardToWFTM(activeIndex);
                } else if (_handler != address(0)) {
                    IERC20Upgradeable(rewardToken).approve(_handler, tokenBal);
                    IExternalHandler(_handler).handle(rewardToken, tokenBal);
                }

                WFTMBalAfter = IERC20Upgradeable(WFTM).balanceOf(address(this));
                totalHarvest += (WFTMBalAfter - WFTMBalBefore);
                catBoostWFTM = ((WFTMBalAfter - WFTMBalBefore) * catBoostPercent) / PERCENT_DIVISOR;
                catBoostTotal += catBoostWFTM;
                accCatDebt[activeIndex] = 0;
            }
        }

        if (catBoostTotal == 0) {
            return 0;
        }
        return ((catBoostTotal * PERCENT_DIVISOR) / totalHarvest);
    }

    /**
     * @dev Swaps any pool reward token to WFTM
     */
    function _swapRewardToWFTM(uint256 _poolId) internal {
        address[] memory rewardToWFTMPath = poolRewardToWFTMPaths[_poolId];
        address rewardToken = rewardToWFTMPath[0];
        uint256 poolRewardTokenBal = IERC20Upgradeable(rewardToken).balanceOf(address(this));
        if (poolRewardTokenBal != 0 && rewardToken != WFTM) {
            IERC20Upgradeable(rewardToken).safeApprove(UNIROUTER, poolRewardTokenBal);
            IUniswapRouterETH(UNIROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                poolRewardTokenBal,
                0,
                rewardToWFTMPath,
                address(this),
                block.timestamp
            );
        }
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function _chargeFees() internal returns (uint256 callFeeToUser) {
        uint256 WFTMFee = (IERC20Upgradeable(WFTM).balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (WFTMFee != 0) {
            IUniswapRouterETH(UNIROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                WFTMFee,
                0,
                WFTMToUSDCPath,
                address(this),
                block.timestamp
            );
            uint256 USDCBal = IERC20Upgradeable(USDC).balanceOf(address(this));
            callFeeToUser = (USDCBal * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (USDCBal * treasuryFee) / PERCENT_DIVISOR;

            IERC20Upgradeable(USDC).safeTransfer(msg.sender, callFeeToUser);
            IERC20Upgradeable(USDC).safeTransfer(treasury, treasuryFeeToVault);
        }
    }

    /**
     * @dev Swaps all {WFTM} into {BOO}
     */
    function _swapWFTMToBOO() internal {
        uint256 WFTMBalance = IERC20Upgradeable(WFTM).balanceOf(address(this));
        if (WFTMBalance != 0) {
            IUniswapRouterETH(UNIROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                WFTMBalance,
                0,
                WFTMToBOOPath,
                address(this),
                block.timestamp
            );
        }
    }

    function _enterXBOO() internal {
        uint256 booBalance = BOO.balanceOf(address(this));
        XBOO.enter(booBalance);
    }

    /**
     * @dev internal function to pay out magicat depositors for their contribution in boosting the APRs
     * @param percentage - the percentage of the harvest (across all rewards) that was contributed by magicat staking
     */
    function _payMagicatDepositors(uint256 percentage) internal {
        uint256 booBalance = BOO.balanceOf(address(this));
        uint256 magicatsCut = (booBalance * percentage) / PERCENT_DIVISOR;
        uint256 magicatPayout = (magicatsCut * catProvisionFee) / PERCENT_DIVISOR;
        IERC20Upgradeable(BOO).transfer(magicatsHandler, magicatPayout);
    }

    /**
     * @dev internal function to update the amount of the boosted rewards, per pool id, that magicat staking grants
     * @param _poolId - the pool ID to update
     */
    function _writeCatDebt(uint256 _poolId) internal {
        (, uint256 catReward) = IAceLab(aceLab).pendingRewards(_poolId, address(this));
        accCatDebt[_poolId] += catReward;
    }

    /**
     * @dev Function to calculate the total underlaying {BOO} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in XBOO and the AceLab pools.
     */
    function balanceOf() public view override returns (uint256) {
        return balanceOfBOO() + balanceOfXBOO() + balanceOfPool();
    }

    /**
     * @dev It calculates how much {BOO} the contract holds.
     */
    function balanceOfBOO() public view returns (uint256) {
        return BOO.balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {BOO} the contract has staked as XBOO.
     */
    function balanceOfXBOO() public view returns (uint256) {
        return XBOO.BOOBalance(address(this));
    }

    /**
     * @dev It calculates how much {BOO} the strategy has allocated in the AceLab pools
     */
    function balanceOfPool() public view returns (uint256) {
        return XBOO.xBOOForBOO(totalPoolBalance);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the AceLab contract, leaving rewards behind.
     */
    function _reclaimWant() internal override {
        uint256[] memory depositedPoolIDs = depositedPools.values();
        uint256 depositPoolsLength = depositedPoolIDs.length;
        uint256 currentDepositedPoolId;
        for (uint256 index = 0; index < depositPoolsLength; index = _uncheckedInc(index)) {
            currentDepositedPoolId = depositedPoolIDs[index];
            IAceLab(aceLab).emergencyWithdraw(currentDepositedPoolId);
            totalPoolBalance -= poolXBOOBalance[currentDepositedPoolId];
            poolXBOOBalance[currentDepositedPoolId] = 0;
            depositedPools.remove(currentDepositedPoolId);
        }

        IMagicatsHandler(magicatsHandler).massUnstakeMagicats();

        uint256 XBOOBalance = XBOO.balanceOf(address(this));
        XBOO.leave(XBOOBalance);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public override {
        _atLeastRole(GUARDIAN);
        _pause();
        _removeAllowances();
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() public override {
        _atLeastRole(ADMIN);
        _giveAllowances();
        _unpause();
        deposit();
    }

    /**
     * @dev Gives max allowance of {BOO} for the {XBOO} contract,
     * {XBOO} allowance for the {aceLab} contract,
     * {WFTM} allowance for the {UNIROUTER}
     * in addition to allowance to all pool rewards for the {UNIROUTER}.
     */
    function _giveAllowances() internal {
        // Give XBOO permission to use BOO
        BOO.safeApprove(address(XBOO), 0);
        BOO.safeApprove(address(XBOO), type(uint256).max);
        // Give XBOO contract permission to stake XBOO
        XBOO.safeApprove(aceLab, 0);
        XBOO.safeApprove(aceLab, type(uint256).max);
        // Give UNIROUTER permission to swap WFTM to BOO
        IERC20Upgradeable(WFTM).safeApprove(UNIROUTER, 0);
        IERC20Upgradeable(WFTM).safeApprove(UNIROUTER, type(uint256).max);

        _approveMagicatsFor(aceLab);
    }

    /**
     * @dev Removes all allowance of {BOO} for the {XBOO} contract,
     * {XBOO} allowance for the {aceLab} contract,
     * {WFTM} allowance for the {UNIROUTER}
     * in addition to allowance to all pool rewards for the {UNIROUTER}.
     */
    function _removeAllowances() internal {
        // Remove XBOO permission to use BOO
        BOO.safeApprove(address(XBOO), 0);
        // Remove XBOO contract permission to stake XBOO
        XBOO.safeApprove(aceLab, 0);
        // Remove UNIROUTER permission to swap WFTM to BOO
        IERC20Upgradeable(WFTM).safeApprove(UNIROUTER, 0);
        // Remove Magicats approvals for the staking contract
        IERC721Upgradeable(MAGICATS).setApprovalForAll(aceLab, false);
    }

    /**
     * @dev internal helper for setting mass approvals for magicats NFTs to a specified address
     */
    function _approveMagicatsFor(address operator) internal {
        IERC721Upgradeable(MAGICATS).setApprovalForAll(operator, true);
    }

    /**
     * @dev external function, called by MAGICATS_HANDLER usually, but can be bypassed if required, to set magicat staking positions for 1 poolID
     * @param poolID - the poolID of the staking contract the function will change
     * @param IDsToStake - the Magicat NFTs, by ID, that will be staked into the contract
     * @param IDsToUnstake - the Magicat NFTs, by ID, that will be unstaked from the contract
     */
    function updateMagicats(
        uint256 poolID,
        uint256[] memory IDsToStake,
        uint256[] memory IDsToUnstake
    ) public {
        _atLeastRole(MAGICATS_HANDLER);
        if (IDsToUnstake.length > 0) {
            IAceLab(aceLab).withdraw(poolID, 0, IDsToUnstake);
        }

        if (IDsToStake.length > 0) {
            IAceLab(aceLab).deposit(poolID, 0, IDsToStake);
        }
    }

    /**
     * @dev external function for updating the magicatHandler contract
     * @param handler - the address of the new Handler
     * todo - tess IFF magicats have been withdrawn back to magicatHandler, then strategy will leave them there
     * Since that only happens in the case where we do not want the strategy to have access to magicats,
     * we do not pull them back to the strategy when updating, otherwise the strategy maintains custody over the magicats.
     * In this case, we either have them idle in the strategy or deposited in Acelab for boosting, the seemless transition will have to
     * be programmed into the next magicats handler and will accept v1 rfMagicats in exchange for the NFTs
     *
     */
    function setMagicatsHandler(address handler) external {
        _atLeastRole(DEFAULT_ADMIN_ROLE);
        require(magicatsHandler == address(0));
        grantRole(MAGICATS_HANDLER, handler);
        magicatsHandler = handler;
        _approveMagicatsFor(magicatsHandler);
    }

    function _requireExternalHandling(uint256 pid) internal view returns (address) {
        if (idToSpecialHandler[pid].requiresSpecialHandling) {
            return idToSpecialHandler[pid].handler;
        }
        return address(this);
    }

    function setExternalHandlerPid(
        uint256 pid,
        bool toggle,
        address _handler
    ) external {
        _atLeastRole(DEFAULT_ADMIN_ROLE);
        idToSpecialHandler[pid].requiresSpecialHandling = toggle;
        idToSpecialHandler[pid].handler = _handler;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    //required for the strategy interface in existing vault
    function retireStrat() external {}

    /**
     * @dev function to update the fee allocated to magicatStakers
     * @param _fee - the new fee to set
     */
    function updateCatProvisionFee(uint256 _fee) external {
        _atLeastRole(DEFAULT_ADMIN_ROLE);
        require(_fee <= PERCENT_DIVISOR);
        catProvisionFee = _fee;
    }

    /**
     * @dev external function for strategist to set token trading routes for rewards
     * @param poolId - the poolId to set the route for
     * @param routes - the trading route of the token to WFTM
     */
    function setRoute(uint256 poolId, address[] calldata routes) external {
        _atLeastRole(STRATEGIST);
        poolRewardToWFTMPaths[poolId] = routes;
    }

    /// @notice For doing an unchecked increment of an index for gas optimization purposes
    /// @param i - The number to increment
    /// @return The incremented number
    function _uncheckedInc(uint256 i) internal pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    /**
     * @dev function to update the new AceLab contract, due to sensitivity it is a DEFUALT_ADMIN_ROLE function
     * @param _aceLab - the new AceLab contract to deposit into
     * @param _defaultPool - the new default pool in that contract to deposit into
     */
    function migrateNewAcelab(address _aceLab, uint256 _defaultPool) external {
        _atLeastRole(DEFAULT_ADMIN_ROLE);
        require(_aceLab != address(0));
        _reclaimWant();
        _removeAllowances();
        aceLab = _aceLab;
        _giveAllowances();
        setCurrentPoolId(_defaultPool);
        updateMagicats(
            _defaultPool,
            IMagicatsHandler(magicatsHandler).getDepositableMagicats(address(this)),
            new uint256[](0)
        );
        deposit();
    }

    /**
     * @dev public function for setting the default poolId to deposit into
     * @param _newID - the new default pool ID
     */
    function setCurrentPoolId(uint256 _newID) public {
        _atLeastRole(STRATEGIST);
        require(_newID < IAceLab(aceLab).poolLength());
        currentPoolId = _newID;
    }

    /**
     * @dev Gets the minimum of two provided uints.
     */
    function _getMin(uint256 _a, uint256 _b) internal pure returns (uint256 min) {
        if (_a < _b) {
            min = _a;
        } else {
            min = _b;
        }
    }
}
