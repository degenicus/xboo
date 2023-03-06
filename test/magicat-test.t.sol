pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/ReaperAutoCompoundXBoo.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/MagicatsHandlerUpgradeable.sol";
import "../contracts/ReaperVaultv1_3.sol";
import "./abstracts/XbooConstants.t.sol";
import "./xboo-test.t.sol";

contract magicatTest is xBooTest {
    MagicatsHandlerUpgradeable handler;
    MagicatsHandlerUpgradeable handlerIMPL;
    ERC1967Proxy handlerProxy;

    function setUp() public override {
        xBooTest.setUp();

        address msRoles = address(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);
        address[] memory strategists = new address[](1);
        strategists[0] = address(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);

        handlerIMPL = new MagicatsHandlerUpgradeable();
        handlerProxy = new ERC1967Proxy(address(handlerIMPL), "");
        handler = MagicatsHandlerUpgradeable(address(handlerProxy));
        handler.initialize(address(XbooStrat), address(vault), strategists, msRoles);

        vm.label(address(handler), "handler");
        XbooStrat.setMagicatsHandler(address(handler));

        vm.startPrank(user1);
        uint256 startingBalance = Boo.balanceOf(user1);
        vault.deposit(startingBalance);
        vm.stopPrank();
        setAllocations();
    }

    function testMagicatDepositAndWithdraw() public {
        address magicatOwner = 0x60BC5E0440C867eEb4CbcE84bB1123fad2b262B1;
        vm.label(magicatOwner, "magicatOwner");
        vm.startPrank(magicatOwner);
        uint256[] memory ownedMagicats = handler.getDepositableMagicats(magicatOwner);

        //try to deposit without approvals should fail
        vm.expectRevert("ERC721: transfer caller is not owner nor approved");
        handler.deposit(ownedMagicats);

        IMagicat(currentMagicats).setApprovalForAll(address(handler), true);
        handler.deposit(ownedMagicats);
        console.log("here");

        //should not be able to deposit already desposited nfts
        vm.expectRevert("ERC721: transfer caller is not owner nor approved");
        handler.deposit(ownedMagicats);

        vm.stopPrank();

        uint256[] memory depositedMagicats = handler.getDepositedMagicats(magicatOwner);

        //leet hacker ops
        vm.startPrank(address(31337));
        //expect handler to revert on withdrawing someone elses nfts
        vm.expectRevert("!approved");
        handler.withdraw(depositedMagicats);

        vm.stopPrank();
        vm.startPrank(magicatOwner);
        handler.withdraw(depositedMagicats);
    }

    function testMagicatDepositAndSeeProfitOnHarvest() public {
        address magicatOwner = 0x60BC5E0440C867eEb4CbcE84bB1123fad2b262B1;
        vm.startPrank(magicatOwner);
        uint256[] memory ownedMagicats = handler.getDepositableMagicats(magicatOwner);
        IMagicat(currentMagicats).setApprovalForAll(address(handler), true);
        handler.deposit(ownedMagicats);
        vm.stopPrank();

        setMagicatAllocations();

        uint256 iterations = 10;
        uint256 apr;
        uint256 time = uint256(block.timestamp);
        for (uint256 i = 0; i < iterations; i++) {
            vm.warp(time += 13 hours);
            XbooStrat.harvest();
            apr = uint256(XbooStrat.averageAPRAcrossLastNHarvests(6));
            console.log("APR is : %s", apr);
        }

        uint256[] memory userOwnedMagicats = handler.getDepositedMagicats(magicatOwner);
        uint256 userStartingVaultShares = vault.balanceOf(magicatOwner);
        uint256 dueRewardsForAllCats = handler.getMagicatRewards(userOwnedMagicats);
        uint256[] memory subArray = new uint256[](1);
        subArray[0] = userOwnedMagicats[0];
        uint256 dueRewardForSubArray = handler.getMagicatRewards(subArray);

        vm.startPrank(magicatOwner);
        //Assert that helper function returns the same amount as the amount claimed
        handler.claimRewards(subArray);
        uint256 afterClaimingVaultShares = vault.balanceOf(magicatOwner);

        assertEq(dueRewardForSubArray, afterClaimingVaultShares - userStartingVaultShares);

        //Assert that withdrawing claims rewards for the nft
        subArray[0] = userOwnedMagicats[1];
        dueRewardForSubArray = handler.getMagicatRewards(subArray);
        handler.withdraw(subArray);
        uint256 afterWithdrawVaultShares = vault.balanceOf(magicatOwner);
        assertEq(dueRewardForSubArray, afterWithdrawVaultShares - afterClaimingVaultShares);

        //assert that redepositing between harvests does not double rewards
        handler.deposit(subArray);
        assertEq(0, handler.getMagicatRewards(subArray));

        //assert that approving the handler doesnt accidentally allow for nft withdrawal or reward claim
        handler.setApprovalForAll(address(handler), true);
        vm.stopPrank();
        vm.startPrank(address(31337));

        subArray[0] = userOwnedMagicats[2];
        vm.expectRevert("!approved");
        handler.claimRewards(subArray);
        vm.expectRevert("!approved");
        handler.withdraw(subArray);
    }

    function setMagicatAllocations() public {
        uint256 aceLabBalanceBeforeAllocation = IMagicat(currentMagicats).balanceOf(address(currentAceLab));

        vm.startPrank(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);
        handler.massUnstakeMagicats();
        uint256[] memory stratIds = getStrategyMagicats();
        console.log(stratIds.length);
        console.log(stratIds[0]);
        uint256[] memory empty = new uint256[](0);
        bool allocationCompleted = true;
        handler.updateStakedMagicats(HEC_ID, stratIds, empty, allocationCompleted);
        vm.stopPrank();

        uint256 stratBalanceAfterAllocation = IMagicat(currentMagicats).balanceOf(address(XbooStrat));
        uint256 aceLabBalanceAfterAllocation = IMagicat(currentMagicats).balanceOf(address(currentAceLab));
        console.log("acelab nft balance before allocation %s", aceLabBalanceBeforeAllocation);
        console.log("strat nft balance after allocation %s", stratBalanceAfterAllocation);
        console.log("acelab nft after before allocation %s", aceLabBalanceAfterAllocation);
    }

    function setMagicatAllocations(MagicatsHandlerUpgradeable _handler) public {
        uint256 aceLabBalanceBeforeAllocation = IMagicat(currentMagicats).balanceOf(address(currentAceLab));

        vm.startPrank(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);
        _handler.massUnstakeMagicats();
        uint256[] memory stratIds = getStrategyMagicats();
        console.log(stratIds.length);
        console.log(stratIds[0]);
        uint256[] memory empty = new uint256[](0);
        bool allocationCompleted = true;
        _handler.updateStakedMagicats(HEC_ID, stratIds, empty, allocationCompleted);
        vm.stopPrank();

        uint256 stratBalanceAfterAllocation = IMagicat(currentMagicats).balanceOf(address(XbooStrat));
        uint256 aceLabBalanceAfterAllocation = IMagicat(currentMagicats).balanceOf(address(currentAceLab));
        console.log("acelab nft balance before allocation %s", aceLabBalanceBeforeAllocation);
        console.log("strat nft balance after allocation %s", stratBalanceAfterAllocation);
        console.log("acelab nft after before allocation %s", aceLabBalanceAfterAllocation);
    }

    function getStrategyMagicats() public returns (uint256[] memory) {
        uint256 balance = IMagicat(currentMagicats).balanceOf(address(XbooStrat));
        uint256[] memory ids = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            ids[i] = IMagicat(currentMagicats).tokenOfOwnerByIndex(address(XbooStrat), i);
        }

        return ids;
    }
}
