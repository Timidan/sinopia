// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sinopia} from "../../src/Sinopia.sol";

contract SinopiaForkTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant BIDDER = address(0xB1D);
    Sinopia fresco;

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        fresco = new Sinopia(INTAKE, IMD);
        deal(IMD, BIDDER, 1 ether, true);
        vm.prank(BIDDER);
        IERC20(IMD).approve(address(fresco), 1 ether);
    }

    function testLiveIntakePaymentAndSimulatedDelivery() public {
        vm.prank(BIDDER);
        fresco.bid(1, 0.55 ether, "A blue river over warm hills");
        uint256 beforeSettle = IERC20(IMD).balanceOf(address(fresco));
        vm.warp(fresco.getRound(1).endTime);
        fresco.settle(1);
        assertEq(beforeSettle - IERC20(IMD).balanceOf(address(fresco)), 0.5 ether);
        bytes32 requestId = fresco.getRound(1).requestId;
        assertTrue(requestId != bytes32(0));
        bytes memory json = vm.readFileBinary("test/fixtures/image-23e66772.canonical.json");
        vm.prank(INTAKE);
        fresco.onResult(requestId, keccak256(json), "ipfs://simulated");
        uint256 burnBefore = IERC20(IMD).balanceOf(fresco.BURN());
        fresco.reveal(1, json);
        assertEq(fresco.ownerOf(1), BIDDER);
        assertEq(IERC20(IMD).balanceOf(fresco.BURN()) - burnBefore, 0.05 ether);
    }
}
