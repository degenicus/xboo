// SPDX-License-Identifier: MIT

import "./abstract/ReaperBaseStrategy.sol";
import "./interfaces/IAceLab.sol";
import "./interfaces/IBooMirrorWorld.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "./interfaces/IPaymentRouter.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SignedSafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

import "hardhat/console.sol";

pragma solidity 0.8.9;

/**
 * @dev This is a strategy to stake Boo into xBoo, and then stake xBoo in different pools to collect more rewards
 * The strategy will compound the pool rewards into Boo which will be deposited into the strategy for more yield.
 */
contract ReaperAutoCompoundXBoov2 is ReaperBaseStrategyv3, IERC721ReceiverUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IBooMirrorWorld;
    using SafeMathUpgradeable for uint256;
    using SignedSafeMathUpgradeable for int256;

    /**
     * @dev Tokens Used:
     * {wftm} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {xBoo} - Token generated by staking our funds. Also used to stake in secondary pools.
     * {Boo} - Token that the strategy maximizes.
     */
    address public constant wftm = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    IBooMirrorWorld public constant xBoo =
        IBooMirrorWorld(0xa48d959AE2E88f1dAA7D5F611E01908106dE7598); // xBoo
    IERC20Upgradeable public constant Boo =
        IERC20Upgradeable(0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE); // Boo

    /**
     * @dev Third Party Contracts:
     * {uniRouter} - the uniRouter for target DEX
     * {aceLab} - Address to AceLab, the SpookySwap contract to stake xBoo
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
     * {wftmToBooPaths} - Route we take to get from {wftm} into {Boo}.
     * {poolRewardToWftmPaths} - Routes for each pool to get from {pool reward token} into {wftm}.
     */
    address[] public wftmToBooPaths;
    mapping(uint256 => address[]) public poolRewardToWftmPaths;

    /**
     * @dev Variables for pool selection
     * {currentPoolId} - Pool id for the the current pool the strategy deposits xBoo into
     * {currentlyUsedPools} - A list of all pool ids currently being used by the strategy
     * {poolYield} - The estimated yield in wftm for each pool over the next 1 day
     * {hasAllocatedToPool} - If a given pool id has been deposited into already for a harvest cycle
     * {maxPoolDilutionFactor} - The factor that determines what % of a pools total TVL can be deposited (to avoid dilution)
     * In Basis points so 10000 = 100%, can be any % of the pool to deposit in
     * {maxNrOfPools} - The maximum amount of pools the strategy can use
     */
    uint256 public currentPoolId;

    /**
     * @dev Variables for pool selection
     * {totalPoolBalance} - The total amount of xBoo currently deposited into pools
     * {poolxBooBalance} - The amount of xBoo deposited into each pool
     */
    uint256 public totalPoolBalance;
    mapping(uint256 => uint256) public poolxBooBalance;
    
    //mapping of poolID -> accumulated catDebt between harvest. accounted for each time catDebt is reset (deposit/withdraw/harvest).
    mapping(uint256 => uint256) public magicBoost;
    uint256 public catBoostPercentage;
    uint256 public catProvisionFee;

    //mapping of poolIds to a flag that specifies if the token requires special preperation to turn into wftm (ex. xTaort)
    mapping(uint256 => bool) public requiresSpecialHandling;
    //mapping of poolIds to addresses of contracts to do external handling of tokens, these can be consolidated or one offs, making this modular allows for all current and future possible rewards to be handled
    mapping(uint256 => address) public specialHandler;

    /**
     * @dev Fee variables
     * {useSecurityFee} - If security fee should be applied on withdraw, controlled by the fee moderator
     */
    bool public useSecurityFee;

    /**
     * {UpdatedStrategist} Event that is fired each time the strategist role is updated.
     */
    event UpdatedStrategist(address newStrategist);

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    constructor(){}
    function initialize(
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
        totalPoolBalance = 0;
        wftmToBooPaths = [wftm, address(Boo)];
        catProvisionFee = 1500;

        _giveAllowances();

    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {Boo} into xBoo (BooMirrorWorld) to farm {xBoo} and finally,
     * xBoo is deposited into other pools to earn additional rewards
     */
    function _deposit() internal override whenNotPaused {
        uint256 BooBalance = Boo.balanceOf(address(this));

        if (BooBalance != 0) {
            xBoo.enter(BooBalance);
            uint256 xBooBalance = xBoo.balanceOf(address(this));
            _aceLabDeposit(currentPoolId, xBooBalance);
        }
    }

    /**
     * @dev Function to deposit into AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabDeposit(uint256 _poolId, uint256 _xBooAmount) internal {
        totalPoolBalance = totalPoolBalance.add(_xBooAmount);
        poolxBooBalance[_poolId] = poolxBooBalance[_poolId].add(
            _xBooAmount
        );
        _writeCatDebt(_poolId);
        IAceLab(aceLab).deposit(_poolId, _xBooAmount);
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {Boo} from the AceLab pools.
     * The available {Boo} minus fees is returned to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        require(msg.sender == vault, "!vault");

        uint256 BooBalance = Boo.balanceOf(address(this));

        if (BooBalance < _amount) {
            
            uint poolLength = IAceLab(aceLab).poolLength();
                // if its an inconsequential amount <5%, then withdraw from first pool, otherwise withdraw equally from all pools
            console.log(
            "_amount is %s\nBooBalance is %s\nbalanceofPool() is %s\n",
            _amount,BooBalance,balanceOfPool()
            );
            
            uint256 withdrawPercentage = (_amount - BooBalance) * 10000 / balanceOfPool();
            console.log("withdraw Percentage %s", withdrawPercentage);           
            for(uint i = 0; i < poolLength; i++){
                if(poolxBooBalance[i] != 0){
                    _aceLabWithdraw(
                        i, 
                        (withdrawPercentage * poolxBooBalance[i]/ 10000)
                    );
                }
            }

            uint256 xBooBalance = xBoo.balanceOf(address(this));
            xBoo.leave(xBooBalance);
            BooBalance = Boo.balanceOf(address(this));
            
        }

        if (BooBalance > _amount) {
            BooBalance = _amount;
        }

        if (useSecurityFee) {
            uint256 withdrawFee = BooBalance.mul(securityFee).div(
                PERCENT_DIVISOR
            );

            Boo.safeTransfer(
                vault,
                BooBalance.sub(withdrawFee)
            );
        } else {
            Boo.safeTransfer(vault, BooBalance);
            useSecurityFee = true;
        }
    }

    /**
     * @dev Function to withdraw from AceLab while keeping internal accounting
     *      updated.
     */
    function _aceLabWithdraw(uint256 _poolId, uint256 _xBooAmount) internal {
        totalPoolBalance = totalPoolBalance.sub(_xBooAmount);
        poolxBooBalance[_poolId] = poolxBooBalance[_poolId].sub(
            _xBooAmount
        );
        _writeCatDebt(_poolId);
        IAceLab(aceLab).withdraw(_poolId, _xBooAmount);
    }

    function setXBooAllocations(
        uint256[] calldata withdrawPoolIds, 
        uint256[] calldata withdrawAmounts, 
        uint256[] calldata depositPoolIds, 
        uint256[] calldata amounts) 
    external {
        _atLeastRole(KEEPER);
        require(
            depositPoolIds.length == amounts.length &&
            withdrawPoolIds.length == withdrawAmounts.length
        );
        require(
            depositPoolIds.length <= IAceLab(aceLab).poolLength() &&
            withdrawPoolIds.length <= IAceLab(aceLab).poolLength()
        );
        for(uint i = 0; i < withdrawPoolIds.length; i++){
            _aceLabWithdraw(withdrawPoolIds[i], withdrawAmounts[i]);
        }

        for(uint i = 0; i < depositPoolIds.length; i++){
            uint256 xBooAvailable = IERC20Upgradeable(xBoo).balanceOf(address(this));
            if (xBooAvailable == 0) {
                return;
            }
            uint256 depositAmount = MathUpgradeable.min(xBooAvailable, amounts[i]);
            _aceLabDeposit(depositPoolIds[i], depositAmount);
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the AceLab pools and estimated the current yield for each pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {wftm} token for {Boo} which is deposited into {xBoo}
     * 4. It distributes the xBoo using a yield optimization algorithm into various pools.
     */
    function _harvestCore() internal override returns (uint256 callerFee) {
        _claimAllRewards();
        catBoostPercentage = _processRewards();
        console.log("returned catBoostPercentage was %s", catBoostPercentage );
        callerFee = _chargeFees(); 
        _swapWftmToBoo();
        _enterXBoo();
        _payMagicatDepositers(catBoostPercentage);
        _aceLabDeposit(currentPoolId, xBoo.balanceOf(address(this)));
    }

    function _claimAllRewards() internal {
        uint256 poolLength = IAceLab(aceLab).poolLength();
        uint256 pending;
        for(uint i = 0; i < poolLength; i++){
            (pending,) = IAceLab(aceLab).pendingRewards(i, address(this));
            if(pending != 0){
                _aceLabWithdraw(i, 0);
            }
        }
    }

    function _processRewards() internal returns (uint256) {
        uint256 poolLength = IAceLab(aceLab).poolLength();
        uint256 tokenBal;
        address _handler;
        uint256 wftmBalBefore;
        uint256 wftBalAfter;
        uint256 catBoostPercent;
        uint256 catBoostWftm;
        uint256 catBoostTotal;
        uint256 totalHarvest;
        address rewardToken;
        for(uint i = 0; i < poolLength; i++){
            rewardToken = address((IAceLab(aceLab)).poolInfo(i).RewardToken);
            tokenBal = IERC20Upgradeable(rewardToken).balanceOf(address(this));
            if(tokenBal != 0){

                wftmBalBefore = IERC20Upgradeable(wftm).balanceOf(address(this));    
                
                //leave is pretty standard for xTokens if it does not have leave we will need an external handler
                try IBooMirrorWorld(rewardToken).leave(tokenBal){
                } catch{}

                if(magicBoost[i] != 0){
                    catBoostPercent = (magicBoost[i] * 10000) / tokenBal;
                    console.log("catBoost percent for index %s is %s", i, catBoostPercent);
                }else{
                    catBoostPercent = 0;
                }


                _handler = _requireExternalHandling(i);
                if(_handler == address(this)){
                    _swapRewardToWftm(i);
                }
                else if(_handler != address(this) && _handler != address(0)){
                    IERC20Upgradeable(rewardToken).approve(_handler, tokenBal);
                    //external call to handler
                }

                wftBalAfter = IERC20Upgradeable(wftm).balanceOf(address(this));
                totalHarvest += (wftBalAfter - wftmBalBefore);
                console.log("wftm harvest for poolId: %s is %s", i, (wftBalAfter - wftmBalBefore));  
                catBoostWftm = ((wftBalAfter - wftmBalBefore) * catBoostPercent) / 10000;
                console.log("of that, catBoostWFTM was %s", catBoostWftm);
                catBoostTotal += catBoostWftm;
                magicBoost[i] = 0;

            }
        }

        if(catBoostTotal == 0){
            return 0;
        }
        return ((catBoostTotal * 10000 ) / totalHarvest);    

    }

   
    /**
     * @dev Swaps any pool reward token to wftm
     */
    function _swapRewardToWftm(uint256 _poolId) internal {
        
        address[] memory rewardToWftmPaths = poolRewardToWftmPaths[_poolId];
        address rewardToken = rewardToWftmPaths[0];
        uint256 poolRewardTokenBal = IERC20Upgradeable(rewardToken).balanceOf(
            address(this)
        );
        if (poolRewardTokenBal != 0 && rewardToken != wftm) {
            IERC20Upgradeable(rewardToken).safeApprove(uniRouter, poolRewardTokenBal);
            IUniswapRouterETH(uniRouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    poolRewardTokenBal,
                    0,
                    rewardToWftmPaths,
                    address(this),
                    block.timestamp.add(600)
                );
        }
    }


    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function _chargeFees() internal returns (uint256 feeToStrategist){
        uint256 wftmFee = IERC20Upgradeable(wftm)
            .balanceOf(address(this))
            .mul(totalFee)
            .div(PERCENT_DIVISOR);

        if (wftmFee != 0) {
            uint256 callFeeToUser = wftmFee.mul(callFee).div(PERCENT_DIVISOR);
            uint256 treasuryFeeToVault = wftmFee.mul(treasuryFee).div(
                PERCENT_DIVISOR
            );
            feeToStrategist = treasuryFeeToVault.mul(strategistFee).div(
                PERCENT_DIVISOR
            );
            treasuryFeeToVault = treasuryFeeToVault.sub(feeToStrategist);

            IERC20Upgradeable(wftm).safeTransfer(msg.sender, callFeeToUser);
            IERC20Upgradeable(wftm).safeTransfer(treasury, treasuryFeeToVault);
        }
    }

    /**
     * @dev Swaps all {wftm} into {Boo}
     */
    function _swapWftmToBoo() internal {
        uint256 wftmBalance = IERC20Upgradeable(wftm).balanceOf(address(this));
        if (wftmBalance != 0) {
            IUniswapRouterETH(uniRouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wftmBalance,
                    0,
                    wftmToBooPaths,
                    address(this),
                    block.timestamp.add(600)
                );
        }
    }

    function _enterXBoo() internal {
        uint256 BooBalance = Boo.balanceOf(address(this));
        xBoo.enter(BooBalance);
    }

    function _payMagicatDepositers(uint256 percentage) internal {
        uint256 xBooBalance = xBoo.balanceOf(address(this));
        uint256 magicatsCut = xBooBalance * percentage / PERCENT_DIVISOR;
        uint256 magicatPayout = magicatsCut * catProvisionFee / PERCENT_DIVISOR;
        console.log(
            "xBooBalance = %s \n magicatsCut = %s \n magicatPayout = %s",
            xBooBalance, magicatsCut, magicatPayout    
        );
        IERC20Upgradeable(xBoo).transfer(magicatsHandler, magicatPayout);
        
    }

    function _writeCatDebt(uint256 _poolId) internal {
        (,uint256 catReward) = IAceLab(aceLab).pendingRewards(_poolId, address(this));
        magicBoost[_poolId] += catReward;
    }

    /**
     * @dev Function to calculate the total underlaying {Boo} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in xBoo and the AceLab pools.
     */
    function balanceOf() public view override returns (uint256) {
        uint256 balance = balanceOfBoo().add(
            balanceOfxBoo().add(balanceOfPool())
        );
        return balance;
    }

    /**
     * @dev It calculates how much {Boo} the contract holds.
     */
    function balanceOfBoo() public view returns (uint256) {
        return Boo.balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {Boo} the contract has staked as xBoo.
     */
    function balanceOfxBoo() public view returns (uint256) {
        return xBoo.BOOBalance(address(this));
    }

    /**
     * @dev It calculates how much {Boo} the strategy has allocated in the AceLab pools
     */
    function balanceOfPool() public view returns (uint256) {
        return xBoo.xBOOForBOO(totalPoolBalance);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the AceLab contract, leaving rewards behind.
     */
    function _reclaimWant() internal override {
        _atLeastRole(STRATEGIST);

        for (uint256 index = 0; index <  IAceLab(aceLab).poolLength(); index++) {
            (uint amount,,,) = IAceLab(aceLab).userInfo(index, address(this));
            if(amount != 0){
                IAceLab(aceLab).emergencyWithdraw(index);
            }
        }
        uint256 xBooBalance = xBoo.balanceOf(address(this));
        xBoo.leave(xBooBalance);

        uint256 BooBalance = Boo.balanceOf(address(this));
        Boo.transfer(vault, BooBalance);
    }

    /**
     * @dev Pauses the strat.
     */
    function _pause() internal override {
        _atLeastRole(STRATEGIST);
        _removeAllowances();
    }

    /**
     * @dev Unpauses the strat.
     */
    function _unpause() internal override {
        _atLeastRole(STRATEGIST);
        _giveAllowances();
    }

    /**
     * @dev Gives max allowance of {Boo} for the {xBoo} contract,
     * {xBoo} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _giveAllowances() internal {
        // Give xBoo permission to use Boo
        Boo.safeApprove(address(xBoo), 0);
        Boo.safeApprove(address(xBoo), type(uint256).max);
        // Give xBoo contract permission to stake xBoo
        xBoo.safeApprove(aceLab, 0);
        xBoo.safeApprove(aceLab, type(uint256).max);
        // Give uniRouter permission to swap wftm to Boo
        IERC20Upgradeable(wftm).safeApprove(uniRouter, 0);
        IERC20Upgradeable(wftm).safeApprove(uniRouter, type(uint256).max);
    }

    /**
     * @dev Removes all allowance of {Boo} for the {xBoo} contract,
     * {xBoo} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _removeAllowances() internal {
        // Remove xBoo permission to use Boo
        Boo.safeApprove(address(xBoo), 0);
        // Remove xBoo contract permission to stake xBoo
        xBoo.safeApprove(aceLab, 0);
        // Remove uniRouter permission to swap wftm to Boo
        IERC20Upgradeable(wftm).safeApprove(uniRouter, 0);
    }

   
    function _approveMagicatsFor(address operator) internal{
        IERC721Upgradeable(Magicats).setApprovalForAll(operator, true);
    }

    function approveMagicats() external {
        _approveMagicatsFor(aceLab);
        _approveMagicatsFor(magicatsHandler);
    }

    
    function updateMagicats(uint poolID, uint[] memory IDsToStake, uint[] memory IDsToUnstake) external{
        //needs to be secured, called by the handler contract
        _atLeastRole(MAGICATS_HANDLER);
        if(IDsToStake.length > 0){
            IAceLab(aceLab).deposit(poolID, 0, IDsToStake);
        }

        if(IDsToUnstake.length > 0){
            IAceLab(aceLab).withdraw(poolID, 0, IDsToUnstake);
        }
    }

    function updateMagicatsHandler(address handler) external {
        _atLeastRole(STRATEGIST);
        if(magicatsHandler != address(0)){    
            revokeRole(MAGICATS_HANDLER, magicatsHandler);
        }
        grantRole(MAGICATS_HANDLER, handler);
        magicatsHandler = handler;
    }

    function _requireExternalHandling(uint256 pid) internal view returns (address) {
        if(requiresSpecialHandling[pid] == true){
            return specialHandler[pid];
        }else{
            return address(this);
        }
    }

        function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4){
        return this.onERC721Received.selector;
    }

    function retireStrat() external{
        vault;
    }

    function updateCatProvisionFee(uint256 _fee) external {
        _atLeastRole(STRATEGIST);
        catProvisionFee = _fee;
    }

    function setRoute(uint256 poolId, address[] calldata routes) external {
        _atLeastRole(STRATEGIST);
        poolRewardToWftmPaths[poolId] = routes;
    }
}


