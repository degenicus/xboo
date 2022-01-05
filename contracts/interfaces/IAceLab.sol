// SPDX-License-Identifier: MIT

import "./IERC20.sol";

pragma solidity 0.8.9;

interface IAceLab {
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct PoolInfo {
        IERC20 RewardToken; // Address of reward token contract.
        uint256 RewardPerSecond; // reward token per second for this pool
        uint256 TokenPrecision; // The precision factor used for calculations, dependent on a tokens decimals
        uint256 xBooStakedAmount; // # of xboo allocated to this pool
        uint256 lastRewardTime; // Last block time that reward distribution occurs.
        uint256 accRewardPerShare; // Accumulated reward per share, times the pools token precision. See below.
        uint256 endTime; // end time of pool
        uint256 startTime; // start time of pool
        uint256 userLimitEndTime;
        address protocolOwnerAddress; // this address is the owner of the protocol corresponding to the reward token, used for emergency withdraw to them only
    }

    function poolInfo(uint256 _index) external view returns (PoolInfo memory);

    function poolLength() external view returns (uint256);

    // View function to see pending BOOs on frontend.
    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() external;

    // Deposit tokens.
    function deposit(uint256 _pid, uint256 _amount) external;

    // Withdraw tokens.
    function withdraw(uint256 _pid, uint256 _amount) external;

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external;
}
