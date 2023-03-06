pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/MagicatsHandlerUpgradeable.sol";
import "./abstracts/XbooConstants.t.sol";

contract ProductionMagicatUpgrade is XbooConstants {
    uint256 public fantomFork;
    address payable public existingHandler = payable(0xD3BF27E1606dF8Ac80f4Fd3c4faF47b8c31a1021);
    MagicatsHandlerUpgradeable public currentHandler;
    MagicatsHandlerUpgradeable public newHandler;

    uint256 public oldMP;
    uint256 public oldSupply;

    function setUp() public {

        fantomFork = vm.createSelectFork('https://rpc.ankr.com/fantom', 56188257);
        currentHandler = MagicatsHandlerUpgradeable(existingHandler);
        vm.label(existingHandler, "handler");
        oldMP = currentHandler.totalMp();
        oldSupply = currentHandler.totalSupply();
        console.log("oldMP: ", oldMP);
        console.log("oldSupply: ", oldSupply);
        newHandler = new MagicatsHandlerUpgradeable();
        console.log("address(newHandler): ", address(newHandler));
    }

    function testHandlerProductionUpgradeValidity() public {

        vm.startPrank(0xe1610bB38Ce95254dD77cbC82F9c1148569B560e);
        currentHandler.upgradeTo(address(newHandler));

        uint256 newMP = currentHandler.totalMp();
        uint256 newSupply = currentHandler.totalSupply();
        console.log("newMP: ", newMP);
        console.log("newSupply: ", newSupply);
        //assertGe(newMP, oldMP);
        //assertGe(newSupply, oldSupply);

        uint256 id = 1786;
        uint256 _harvests = 260;

        uint256 beforePartialPending = currentHandler.getMagicatReward(id);

        currentHandler.partialClaimRewards(id, _harvests);

        uint256 afterPartialPending = currentHandler.getMagicatReward(id);

        assertEq(beforePartialPending, afterPartialPending);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.stopPrank();
        vm.prank(0x60BC5E0440C867eEb4CbcE84bB1123fad2b262B1);
        currentHandler.claimRewards(ids);

        assertEq(currentHandler.getMagicatReward(id), 0);
        

    }
}
