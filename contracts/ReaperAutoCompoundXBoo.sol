// SPDX-License-Identifier: MIT

import "./abstract/Ownable.sol";
import "./abstract/Pausable.sol";
import "./abstract/ReaperBaseStrategy.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IAceLab.sol";
import "./interfaces/IBooMirrorWorld.sol";
import "./interfaces/IUniswapRouterETH.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";

import "hardhat/console.sol";

pragma solidity 0.8.9;

/**
 * @dev This is a strategy to stake Boo into xBoo, and then stake xBoo in different pools to collect more rewards
 * The strategy will compound the pool rewards into Boo which will be deposited into the strategy for more yield.
 */
contract ReaperAutoCompoundXBoo is ReaperBaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wftm} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {xBoo} - Token generated by staking our funds. Also used to stake in secondary pools.
     * {boo} - Token that the strategy maximizes.
     */
    address public wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public xBoo;
    address public boo;

    /**
     * @dev Third Party Contracts:
     * {uniRouter} - the uniRouter for target DEX
     * {aceLab} - Address to AceLab, the SpookySwap contract to stake xBoo
     */
    address public uniRouter;
    address public aceLab;

    /**
     * @dev Reaper Contracts:
     * {treasury} - Address of the Reaper treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address public treasury;
    address public vault;

    /**
     * @dev Reaper Roles:
     * {strategist} - address of the strategist responsible for keeping strategy variables updated
     */
    address public strategist;

    /**
     * @dev Routes we take to swap tokens
     * {wftmToBooRoute} - Route we take to get from {wftm} into {boo}.
     * {poolRewardToWftmPaths} - Routes for each pool to get from {pool reward token} into {wftm}.
     */
    address[] public wftmToBooRoute;
    mapping(uint8 => address[]) public poolRewardToWftmPaths;

    /**
     * @dev Variables for pool selection
     * {currentPoolId} - Pool id for the the current pool the strategy deposits xBoo into
     * {currentlyUsedPools} - A list of all pool ids currently being used by the strategy
     * {poolYield} - The estimated yield in wftm for each pool over the next 1 day
     * {hasAllocatedToPool} - If a given pool id has been deposited into already for a harvest cycle
     * {WFTM_POOL_ID} - Id for the wftm pool to use as default pool before pool selection
     * {maxPoolDilutionFactor} - The factor that determines what % of a pools total TVL can be deposited (to avoid dilution)
     */
    uint8 public currentPoolId;
    uint8[] public currentlyUsedPools;
    mapping(uint8 => uint256) public poolYield;
    mapping(uint8 => bool) public hasAllocatedToPool;
    uint8 private constant WFTM_POOL_ID = 2;
    uint8 public maxPoolDilutionFactor = 5;

    /**
     * @dev Variables for pool selection
     * {totalPoolBalance} - The total amount of xBoo currently deposited into pools
     * {poolxBooBalance} - The amount of xBoo deposited into each pool
     */
    uint256 public totalPoolBalance = 0;
    mapping(uint8 => uint256) public poolxBooBalance;

    /**
     * {UpdatedStrategist} Event that is fired each time the strategist role is updated.
     */
    event UpdatedStrategist(address newStrategist);

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    constructor(
        address _uniRouter,
        address _aceLab,
        address _rewardToken,
        address _xBoo,
        address _vault,
        address _treasury
    ) {
        uniRouter = _uniRouter;
        aceLab = _aceLab;
        boo = _rewardToken;
        xBoo = _xBoo;
        vault = _vault;
        treasury = _treasury;
        wftmToBooRoute = [wftm, boo];
        currentPoolId = WFTM_POOL_ID;

        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {boo} into xBoo (BooMirrorWorld) to farm {xBoo} and finally,
     * xBoo is deposited into other pools to earn additional rewards
     */
    function deposit() public whenNotPaused {
        uint256 booBalance = IERC20(boo).balanceOf(address(this));

        if (booBalance > 0) {
            IBooMirrorWorld(xBoo).enter(booBalance);
            uint256 xBooBalance = IERC20(xBoo).balanceOf(address(this));
            IAceLab(aceLab).deposit(currentPoolId, xBooBalance);
            totalPoolBalance = totalPoolBalance.add(xBooBalance);
            poolxBooBalance[currentPoolId] = poolxBooBalance[currentPoolId].add(
                xBooBalance
            );
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {boo} from the AceLab pools.
     * The available {boo} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 booBalance = IERC20(boo).balanceOf(address(this));

        if (booBalance < _amount) {
            for (
                uint256 index = 0;
                index < currentlyUsedPools.length;
                index++
            ) {
                uint8 poolId = currentlyUsedPools[index];
                uint256 currentPoolxBooBalance = poolxBooBalance[poolId];
                if (currentPoolxBooBalance > 0) {
                    uint256 remainingBooAmount = _amount - booBalance;
                    uint256 remainingxBooAmount = IBooMirrorWorld(xBoo)
                        .BOOForxBOO(remainingBooAmount);
                    uint256 withdrawAmount;
                    if (remainingxBooAmount > currentPoolxBooBalance) {
                        withdrawAmount = currentPoolxBooBalance;
                    } else {
                        withdrawAmount = remainingxBooAmount;
                    }
                    IAceLab(aceLab).withdraw(poolId, withdrawAmount);
                    totalPoolBalance = totalPoolBalance.sub(withdrawAmount);
                    poolxBooBalance[poolId] = poolxBooBalance[poolId].sub(
                        withdrawAmount
                    );
                    uint256 xBooBalance = IERC20(xBoo).balanceOf(address(this));
                    IBooMirrorWorld(xBoo).leave(xBooBalance);
                    booBalance = IERC20(boo).balanceOf(address(this));
                    if (booBalance >= _amount) {
                        break;
                    }
                }
            }
        }

        if (booBalance > _amount) {
            booBalance = _amount;
        }
        uint256 withdrawFee = booBalance.mul(securityFee).div(PERCENT_DIVISOR);
        IERC20(boo).safeTransfer(vault, booBalance.sub(withdrawFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the AceLab pools and estimated the current yield for each pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {wftm} token for {Boo} which is deposited into {xBoo}
     * 4. It distributes the xBoo using a yield optimization algorithm into various pools.
     */
    function _harvestCore() internal override {
        _collectRewardsAndEstimateYield();
        _chargeFees();
        _compoundRewards();
        _rebalance();
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest()
        external
        view
        override
        returns (uint256 profit, uint256 callFeeToUser)
    {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            uint8 poolId = currentlyUsedPools[index];
            uint256 pendingReward = IAceLab(aceLab).pendingReward(
                poolId,
                address(this)
            );
            if (pendingReward == 0) {
                continue;
            }
            address rewardToken = address(
                IAceLab(aceLab).poolInfo(poolId).RewardToken
            );
            if (rewardToken == wftm) {
                profit = profit.add(pendingReward);
            } else {
                address[] memory path = new address[](2);
                path[0] = rewardToken;
                path[1] = wftm;

                uint256[] memory amountOutMins = IUniswapRouterETH(uniRouter)
                    .getAmountsOut(pendingReward, path);
                profit = profit.add(amountOutMins[1]);
            }
        }

        // // take out fees from profit
        uint256 wftmFee = profit.mul(totalFee).div(PERCENT_DIVISOR);
        callFeeToUser = wftmFee.mul(callFee).div(PERCENT_DIVISOR);
        profit = profit.sub(wftmFee);
    }

    /**
     * @dev Collects reward tokens from all used pools, swaps it into wftm and estimates
     * the yield for each pool.
     */
    function _collectRewardsAndEstimateYield() internal {
        uint256 nrOfUsedPools = currentlyUsedPools.length;
        for (uint256 index = 0; index < nrOfUsedPools; index++) {
            uint8 poolId = currentlyUsedPools[index];
            uint256 currentPoolxBooBalance = poolxBooBalance[poolId];
            IAceLab(aceLab).withdraw(poolId, currentPoolxBooBalance);
            totalPoolBalance = totalPoolBalance.sub(currentPoolxBooBalance);
            poolxBooBalance[poolId] = 0;
            _swapRewardToWftm(poolId);
            _setEstimatedYield(poolId);
            hasAllocatedToPool[poolId] = false;
        }
    }

    /**
     * @dev Swaps any pool reward token to wftm
     */
    function _swapRewardToWftm(uint8 _poolId) internal {
        address[] memory rewardToWftmPaths = poolRewardToWftmPaths[_poolId];
        IERC20 rewardToken = IAceLab(aceLab).poolInfo(_poolId).RewardToken;
        uint256 poolRewardTokenBal = rewardToken.balanceOf(address(this));
        if (poolRewardTokenBal > 0 && address(rewardToken) != wftm) {
            // Default to support empty or incomplete path array
            if (rewardToWftmPaths.length < 2) {
                rewardToWftmPaths = new address[](2);
                rewardToWftmPaths[0] = address(rewardToken);
                rewardToWftmPaths[1] = wftm;
            }
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
     * @dev Swaps any pool reward token to wftm
     */
    function _setEstimatedYield(uint8 _poolId) internal {
        IAceLab.PoolInfo memory poolInfo = IAceLab(aceLab).poolInfo(_poolId);
        uint256 _from = block.timestamp;
        uint256 _to = block.timestamp + 1 days;
        uint256 multiplier;
        _from = _from > poolInfo.startTime ? _from : poolInfo.startTime;
        if (_from > poolInfo.endTime || _to < poolInfo.startTime) {
            multiplier = 0;
        }
        if (_to > poolInfo.endTime) {
            multiplier = poolInfo.endTime - _from;
        }
        multiplier = _to - _from;
        uint256 totalTokens = multiplier * poolInfo.RewardPerSecond;

        if (address(poolInfo.RewardToken) == wftm) {
            uint256 wftmYield = (1 ether * totalTokens) /
                poolInfo.xBooStakedAmount;
            poolYield[_poolId] = wftmYield;
        } else {
            if (totalTokens == 0) {
                poolYield[_poolId] = 0;
            } else {
                address[] memory path = new address[](2);
                path[0] = address(poolInfo.RewardToken);
                path[1] = wftm;
                uint256 wftmTotalPoolYield = IUniswapRouterETH(uniRouter)
                    .getAmountsOut(totalTokens, path)[1];
                uint256 wftmYield = (1 ether * wftmTotalPoolYield) /
                    poolInfo.xBooStakedAmount;
                poolYield[_poolId] = wftmYield;
            }
        }
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function _chargeFees() internal {
        if (totalFee != 0) {
            uint256 wftmBalance = IERC20(wftm).balanceOf(address(this));
            uint256 wftmFee = wftmBalance.mul(totalFee).div(PERCENT_DIVISOR);

            uint256 callFeeToUser = wftmFee.mul(callFee).div(PERCENT_DIVISOR);
            IERC20(wftm).safeTransfer(msg.sender, callFeeToUser);

            uint256 treasuryFeeToVault = wftmFee.mul(treasuryFee).div(
                PERCENT_DIVISOR
            );
            IERC20(wftm).safeTransfer(treasury, treasuryFeeToVault);
        }
    }

    /**
     * @dev Swaps all {wftm} into {boo} which it deposits into {xBoo}
     */
    function _compoundRewards() internal {
        uint256 wftmBalance = IERC20(wftm).balanceOf(address(this));
        if (wftmBalance > 0) {
            IUniswapRouterETH(uniRouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wftmBalance,
                    0,
                    wftmToBooRoute,
                    address(this),
                    block.timestamp.add(600)
                );
            uint256 booBalance = IERC20(boo).balanceOf(address(this));
            IBooMirrorWorld(xBoo).enter(booBalance);
        }
    }

    /**
     * @dev Deposits into the highest yielding pool, up to a cap set by {maxPoolDilutionFactor}
     * If xBoo remains to be deposited picks the 2nd highest yielding pool and so on.
     */
    function _rebalance() internal {
        uint256 xBooBalance = IERC20(xBoo).balanceOf(address(this));
        while (xBooBalance > 0) {
            uint256 bestYield = 0;
            uint8 bestYieldPoolId = currentlyUsedPools[0];
            uint256 bestYieldIndex = 0;
            for (
                uint256 index = 0;
                index < currentlyUsedPools.length;
                index++
            ) {
                uint8 poolId = currentlyUsedPools[index];
                if (hasAllocatedToPool[poolId] == false) {
                    uint256 currentPoolYield = poolYield[poolId];
                    if (currentPoolYield >= bestYield) {
                        bestYield = currentPoolYield;
                        bestYieldPoolId = poolId;
                        bestYieldIndex = index;
                    }
                }
            }
            uint256 poolDepositAmount = xBooBalance;
            IAceLab.PoolInfo memory poolInfo = IAceLab(aceLab).poolInfo(
                bestYieldPoolId
            );
            bool isNotWFTM = address(poolInfo.RewardToken) != wftm;
            if (
                isNotWFTM &&
                poolDepositAmount >
                (poolInfo.xBooStakedAmount / maxPoolDilutionFactor)
            ) {
                poolDepositAmount =
                    poolInfo.xBooStakedAmount /
                    maxPoolDilutionFactor;
            }
            IAceLab(aceLab).deposit(bestYieldPoolId, poolDepositAmount);
            totalPoolBalance = totalPoolBalance.add(poolDepositAmount);
            poolxBooBalance[bestYieldPoolId] = poolxBooBalance[bestYieldPoolId]
                .add(poolDepositAmount);
            hasAllocatedToPool[bestYieldPoolId] = true;
            xBooBalance = IERC20(xBoo).balanceOf(address(this));
            currentPoolId = bestYieldPoolId;
        }
    }

    /**
     * @dev Function to calculate the total underlaying {boo} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in xBoo and the AceLab pools.
     */
    function balanceOf() public view override returns (uint256) {
        uint256 balance = balanceOfBoo().add(
            balanceOfxBoo().add(balanceOfPool())
        );
        return balance;
    }

    /**
     * @dev It calculates how much {boo} the contract holds.
     */
    function balanceOfBoo() public view returns (uint256) {
        return IERC20(boo).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {boo} the contract has staked as xBoo.
     */
    function balanceOfxBoo() public view returns (uint256) {
        return IBooMirrorWorld(xBoo).BOOBalance(address(this));
    }

    /**
     * @dev It calculates how much {boo} the strategy has allocated in the AceLab pools
     */
    function balanceOfPool() public view returns (uint256) {
        return IBooMirrorWorld(xBoo).xBOOForBOO(totalPoolBalance);
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            uint8 poolId = currentlyUsedPools[index];
            uint256 balance = poolxBooBalance[poolId];
            IAceLab(aceLab).withdraw(poolId, balance);
            totalPoolBalance = totalPoolBalance.sub(balance);
            poolxBooBalance[poolId] = 0;
            _swapRewardToWftm(poolId);
        }

        _compoundRewards();

        uint256 xBooBalance = IERC20(xBoo).balanceOf(address(this));
        IBooMirrorWorld(xBoo).leave(xBooBalance);

        uint256 booBalance = IERC20(boo).balanceOf(address(this));
        IERC20(boo).transfer(vault, booBalance);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the AceLab contract, leaving rewards behind.
     */
    function panic() public onlyOwner {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            uint8 poolId = currentlyUsedPools[index];
            IAceLab(aceLab).emergencyWithdraw(poolId);
        }
        uint256 xBooBalance = IERC20(xBoo).balanceOf(address(this));
        IBooMirrorWorld(xBoo).leave(xBooBalance);

        uint256 booBalance = IERC20(boo).balanceOf(address(this));
        IERC20(boo).transfer(vault, booBalance);

        pause();
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();
        _removeAllowances();
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        _giveAllowances();

        deposit();
    }

    /**
     * @dev Gives max allowance of {boo} for the {xBoo} contract,
     * {xBoo} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _giveAllowances() internal {
        // Give xBOO permission to use Boo
        IERC20(boo).safeApprove(xBoo, 0);
        IERC20(boo).safeApprove(xBoo, type(uint256).max);
        // Give xBoo contract permission to stake xBoo
        IERC20(xBoo).safeApprove(aceLab, 0);
        IERC20(xBoo).safeApprove(aceLab, type(uint256).max);
        // Give uniRouter permission to swap wftm to boo
        IERC20(wftm).safeApprove(uniRouter, 0);
        IERC20(wftm).safeApprove(uniRouter, type(uint256).max);
        _givePoolAllowances();
    }

    /**
     * @dev Removes all allowance of {boo} for the {xBoo} contract,
     * {xBoo} allowance for the {aceLab} contract,
     * {wftm} allowance for the {uniRouter}
     * in addition to allowance to all pool rewards for the {uniRouter}.
     */
    function _removeAllowances() internal {
        // Give xBOO permission to use Boo
        IERC20(boo).safeApprove(xBoo, 0);
        // Give xBoo contract permission to stake xBoo
        IERC20(xBoo).safeApprove(aceLab, 0);
        // Give uniRouter permission to swap wftm to boo
        IERC20(wftm).safeApprove(uniRouter, 0);
        _removePoolAllowances();
    }

    /**
     * @dev Gives max allowance to all pool rewards for the {uniRouter}.
     */
    function _givePoolAllowances() internal {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            IERC20 rewardToken = IAceLab(aceLab)
                .poolInfo(currentlyUsedPools[index])
                .RewardToken;
            rewardToken.safeApprove(uniRouter, 0);
            rewardToken.safeApprove(uniRouter, type(uint256).max);
        }
    }

    /**
     * @dev Removes all allowance to all pool rewards for the {uniRouter}.
     */
    function _removePoolAllowances() internal {
        for (uint256 index = 0; index < currentlyUsedPools.length; index++) {
            uint8 poolId = currentlyUsedPools[index];
            IAceLab(aceLab).poolInfo(poolId).RewardToken.safeApprove(
                uniRouter,
                0
            );
        }
    }

    /**
     * @dev updates the treasury
     */
    function updateTreasury(address newTreasury)
        external
        onlyOwner
        returns (bool)
    {
        treasury = newTreasury;
        return true;
    }

    /**
     * @dev updates the {maxPoolDilutionFactor}
     */
    function updateMaxPoolDilutionFactor(uint8 _maxPoolDilutionFactor)
        external
    {
        _onlyAuthorized();
        require(
            _maxPoolDilutionFactor > 0,
            "Must be a positive pool dilution factor"
        );
        maxPoolDilutionFactor = _maxPoolDilutionFactor;
    }

    /**
     * @dev Adds a pool from the {aceLab} contract to be actively used to yield.
     * _poolRewardToWftmPath can be empty if the paths are standard rewardToken -> wftm
     */
    function addUsedPool(uint8 _poolId, address[] memory _poolRewardToWftmPath)
        external
    {
        _onlyAuthorized();
        require(
            _poolRewardToWftmPath.length >= 2,
            "Must have at least 2 addresses in reward path"
        );
        currentlyUsedPools.push(_poolId);
        poolRewardToWftmPaths[_poolId] = _poolRewardToWftmPath;
        address poolRewardToken;
        if (_poolRewardToWftmPath.length > 0) {
            poolRewardToken = _poolRewardToWftmPath[0];
        } else {
            poolRewardToken = address(
                IAceLab(aceLab).poolInfo(_poolId).RewardToken
            );
        }
        if (poolRewardToken != wftm) {
            IERC20(poolRewardToken).safeApprove(uniRouter, type(uint256).max);
        }
    }

    /**
     * @dev Removes a pool that will no longer be used.
     */
    function removeUsedPool(uint8 _poolIndex) external {
        _onlyAuthorized();
        uint8 poolId = currentlyUsedPools[_poolIndex];
        if (currentPoolId == poolId) {
            currentPoolId = WFTM_POOL_ID;
        }
        IAceLab(aceLab).poolInfo(poolId).RewardToken.safeApprove(uniRouter, 0);
        uint256 balance = poolxBooBalance[poolId];
        IAceLab(aceLab).withdraw(poolId, balance);
        totalPoolBalance = totalPoolBalance.sub(balance);
        poolxBooBalance[poolId] = 0;
        uint256 lastPoolIndex = currentlyUsedPools.length - 1;
        uint8 lastPoolId = currentlyUsedPools[lastPoolIndex];
        currentlyUsedPools[_poolIndex] = lastPoolId;
        currentlyUsedPools.pop();

        if (poolId == WFTM_POOL_ID) {
            currentPoolId = currentlyUsedPools[0];
        }
    }

    /**
     * @dev Updates the current strategist.
     *  This may only be called by owner or the existing strategist.
     */
    function setStrategist(address _strategist) external {
        _onlyAuthorized();
        require(_strategist != address(0), "Can't set strategist to 0 address");
        strategist = _strategist;
        emit UpdatedStrategist(_strategist);
    }

    /**
     * @dev Only allow access to strategist or owner
     */
    function _onlyAuthorized() internal view {
        require(
            msg.sender == strategist || msg.sender == owner(),
            "Not authorized"
        );
    }
}
