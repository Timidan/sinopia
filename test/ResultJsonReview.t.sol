// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Sinopia} from "../src/Sinopia.sol";
import {MockIMD, MockIntake} from "./Sinopia.t.sol";

contract ResultJsonReviewTest is Test {
    function _delivered(bytes memory result) internal returns (Sinopia auction, address bidder) {
        MockIMD imd = new MockIMD();
        MockIntake intake = new MockIntake(imd);
        auction = new Sinopia(address(intake), address(imd));
        bidder = address(0xA11CE);
        imd.mint(bidder, 0.55 ether);
        vm.startPrank(bidder);
        imd.approve(address(auction), 0.55 ether);
        auction.bid(1, 0.55 ether, "A blue river over warm hills");
        vm.stopPrank();
        vm.warp(auction.getRound(1).endTime);
        auction.settle(1);

        bytes32 requestId = auction.getRound(1).requestId;
        vm.prank(address(intake));
        auction.onResult(requestId, keccak256(result), "ipfs://result");
    }

    function testImageFileWithBraceInEvaluationCannotBeRefunded() public {
        bytes memory result = bytes(
            vm.replace(
                vm.readFile("test/fixtures/image-23e66772.canonical.json"),
                '"evaluation":"structural"',
                '"evaluation":"review } passed"'
            )
        );
        (Sinopia auction, address bidder) = _delivered(result);
        vm.expectRevert();
        auction.rejectDelivery(1, result);
        auction.reveal(1, result);
        assertEq(auction.ownerOf(1), bidder);
    }

    function testTopLevelKeysAroundMarkersReveal() public {
        string memory json = vm.readFile("test/fixtures/image-23e66772.canonical.json");
        json = vm.replace(json, '{"complete":true', '{"alpha":{"nested":[1,":}"]},"complete":true');
        json = vm.replace(json, '"state":"completed"}', '"state":"completed","zeta":[{"x":0}]}');
        bytes memory result = bytes(json);
        (Sinopia auction, address bidder) = _delivered(result);
        auction.reveal(1, result);
        assertEq(auction.ownerOf(1), bidder);
    }

    function testNestedImageFileValueReveal() public {
        bytes memory result = bytes(
            vm.replace(
                vm.readFile("test/fixtures/image-23e66772.canonical.json"),
                '"evaluation":"structural"',
                '"evaluation":{"nested":{"name":"other","hash":"bad","text":"} [, :"}}'
            )
        );
        (Sinopia auction, address bidder) = _delivered(result);
        auction.reveal(1, result);
        assertEq(auction.ownerOf(1), bidder);
    }
}
