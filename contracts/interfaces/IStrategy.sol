// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStrategy {
    //deposits all funds into the farm
    function deposit() external;

    //vault only - withdraws funds from the strategy
    function withdraw(uint256 _amount) external;

    //returns the balance of all tokens managed by the strategy
    function balanceOf() external view returns (uint256);

    //claims farmed tokens, distributes fees, and sells tokens to re-add to the LP & farm
    function harvest() external returns (uint256 callerFee);

    //withdraws all tokens and sends them back to the vault
    function retireStrat() external;

    //pauses deposits, resets allowances, and withdraws all funds from farm
    function panic() external;

    //pauses deposits and resets allowances
    function pause() external;

    //unpauses deposits and maxes out allowances again
    function unpause() external;

    //updates Total Fee
    function updateTotalFee(uint256 _totalFee) external;

    function currentPoolId() external returns (uint256);

    function updateMagicats(
        uint256 poolID,
        uint256[] memory IDsToStake,
        uint256[] memory IDsToUnstake
    ) external;
}
