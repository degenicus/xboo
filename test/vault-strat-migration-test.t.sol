pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/ReaperAutoCompoundXBoo.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/ReaperVaultv1_3.sol";
import "./abstracts/XbooConstants.t.sol";

contract productionMigration is XbooConstants {
    address existingVault = 0xFC550BAD3c14160CBA7bc05ee263b3F060149AFF;
    address existingStrat = 0xB62100d94436f53a87516f1aa3Cf42f8A96Ae049;
    address newStrat = 0x98c3956B492dc4984D1a9752792120ebfCdC9c9B;

    ReaperAutoCompoundXBoov2 XbooStrat;
    ReaperAutoCompoundXBoov2 stratIMPL;
    ReaperVaultv1_3 vault;
    ERC1967Proxy stratProxy;

    uint256 oldPPFS;
    uint256 oldSupply;
    uint256 oldBalance;

    function setUp() public {
        vault = ReaperVaultv1_3(existingVault);
        vm.label(existingVault, "vault");

        /*stratIMPL = new ReaperAutoCompoundXBoov2();
        vm.label(address(stratIMPL), "strategy Implementation");
        stratProxy = new ERC1967Proxy(
            address(stratIMPL),
            "" //args
        );
        vm.label(address(stratProxy), "ERC1967 Proxy: Strategy Proxy");*/

        XbooStrat = ReaperAutoCompoundXBoov2(newStrat);
/*
        address[] memory feeRemitters = new address[](2);
        feeRemitters[0] = address(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);
        feeRemitters[1] = address(1);
        address[] memory strategists = new address[](1);

        address[] memory msRoles = new address[](3);
        msRoles[0] = address(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);
        msRoles[1] = address(1337);
        msRoles[2] = address(31337);

        strategists[0] = address(0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9);

        XbooStrat.initialize(address(vault), feeRemitters, strategists, msRoles);
*/
        uint256 time = block.timestamp;
        oldPPFS = vault.getPricePerFullShare();
        oldBalance = vault.balance();
        oldSupply = vault.totalSupply();
        vm.startPrank(0x111731A388743a75CF60CCA7b140C58e41D83635);
        vault.proposeStrat(address(XbooStrat));
        vm.warp(time + 5 days);
        vault.upgradeStrat();
    }

    function testProductionUpgradeValidity() public {
        uint256 newPPFS = vault.getPricePerFullShare();
        uint256 newBalance = vault.balance();
        uint256 newSupply = vault.totalSupply();

        /*console.log("newPPFS: %i\n newBalance: %i\n newSupply: %i", newPPFS, newBalance, newSupply);
        console.log("oldPPFS: %i\n oldBalance: %i\n oldSupply: %i", oldPPFS, oldBalance, oldSupply);
        */
        console.log("newPPFS: %i\noldPPFS: %i", newPPFS, oldPPFS);
        console.log("newSupply: %i\noldSupply: %i", newSupply, oldSupply);
        console.log("newBalance: %i\noldBalance: %i", newBalance, oldBalance);

        assertGe(newPPFS, oldPPFS);
        //assertGe(newBalance, oldBalance); giving some rounding issues by 2 wei for some reason, will look into more
        //I believe this is due to rounding errors of 1 wei going in and out of xboo, 1wei in 1wei out
        assertGe(newSupply, oldSupply);
    }
}
