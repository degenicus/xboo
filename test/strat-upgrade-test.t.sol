pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/ReaperAutoCompoundXBoo.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/ReaperVaultv1_3.sol";
import "./abstracts/XbooConstants.t.sol";

contract ProductionStrategyUpgrade is XbooConstants {
    address public existingVault = 0xFC550BAD3c14160CBA7bc05ee263b3F060149AFF;
    address payable public existingStrat = payable(0x98c3956B492dc4984D1a9752792120ebfCdC9c9B);
    ReaperVaultv1_3 public vault;
    ReaperAutoCompoundXBoov2 public currentStrat;
    ReaperAutoCompoundXBoov2 public newStrat;

    uint256 public oldPPFS;
    uint256 public oldSupply;
    uint256 public oldBalance;

    function setUp() public {
        vault = ReaperVaultv1_3(existingVault);
        vm.label(existingVault, "vault");
        oldPPFS = vault.getPricePerFullShare();
        oldBalance = vault.balance();
        oldSupply = vault.totalSupply();
        currentStrat = ReaperAutoCompoundXBoov2(existingStrat);
        console.log("oldPPFS: ", oldPPFS);
        console.log("oldBalance: ", oldBalance);
        console.log("oldSupply: ", oldSupply);
        uint256 balance = currentStrat.balanceOf();
        console.log("balance: ", balance);
        newStrat = new ReaperAutoCompoundXBoov2();
        console.log("address(newStrat): ", address(newStrat));
    }

    function testStrategyProductionUpgradeValidity() public {
        vm.expectRevert();
        uint256 lastAllocation = currentStrat.lastAllocationTimestamp();

        vm.startPrank(0xe1610bB38Ce95254dD77cbC82F9c1148569B560e);
        currentStrat.upgradeTo(address(newStrat));

        uint256 newPPFS = vault.getPricePerFullShare();
        uint256 newBalance = vault.balance();
        uint256 newSupply = vault.totalSupply();
        console.log("newPPFS: ", newPPFS);
        console.log("newBalance: ", newBalance);
        console.log("newSupply: ", newSupply);
        assertGe(newPPFS, oldPPFS);
        assertGe(newBalance, oldBalance);
        assertGe(newSupply, oldSupply);

        lastAllocation = currentStrat.lastAllocationTimestamp();
        console.log("lastAllocation: ", lastAllocation);
        assertEq(lastAllocation, 0);

        uint256[] memory args = new uint256[](0);
        currentStrat.setXBooAllocations(args, args, args, args);
        lastAllocation = currentStrat.lastAllocationTimestamp();
        console.log("lastAllocation: ", lastAllocation);
        assertEq(lastAllocation, block.timestamp);
    }

    function testStrategyProductionUpgradeHarvestValidity() public {
        uint256 callerFee = currentStrat.harvest();
        console.log("callerFee: ", callerFee);
        assertGe(callerFee, 0);

        uint256 time = uint256(block.timestamp);
        vm.warp(time + 24 hours);

        vm.startPrank(0xe1610bB38Ce95254dD77cbC82F9c1148569B560e);
        currentStrat.upgradeTo(address(newStrat));
        vm.stopPrank();

        vm.expectRevert();
        currentStrat.harvest();

        address keeper = makeAddr("keeper");
        vm.startPrank(0xe1610bB38Ce95254dD77cbC82F9c1148569B560e);
        bytes32 keeperRole = 0x71a9859d7dd21b24504a6f306077ffc2d510b4d4b61128e931fe937441ad1836;
        currentStrat.grantRole(keeperRole, keeper);
        vm.stopPrank();
        vm.startPrank(keeper);

        callerFee = currentStrat.harvest();
        console.log("callerFee: ", callerFee);
        assertGe(callerFee, 0);
    }
}
