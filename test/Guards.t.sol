// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Reviewer guard regressions.
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sinopia, IIntake} from "../src/Sinopia.sol";
import {MockIMD, MockIntake} from "./Sinopia.t.sol";

contract FeeIMD is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract ConstIntake is IIntake {
    IERC20 public immutable imd;
    bytes32 public id;

    constructor(IERC20 imd_) {
        imd = imd_;
    }

    function set(bytes32 v) external {
        id = v;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address, uint256 amount)
        external
        returns (bytes32)
    {
        imd.transferFrom(msg.sender, address(this), amount);
        return id;
    }
}

contract GuardTests is Test {
    MockIMD imd;
    MockIntake intake;
    Sinopia fresco;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    string constant BRIEF = "A blue river over warm hills";

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake(imd);
        fresco = new Sinopia(address(intake), address(imd));
        imd.mint(alice, 10 ether);
        imd.mint(bob, 10 ether);
        vm.prank(alice);
        imd.approve(address(fresco), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(fresco), type(uint256).max);
    }

    function _bid(address who, uint256 amount) internal {
        uint256 latest = fresco.latestRoundId();
        uint256 target = latest == 0 || block.timestamp >= fresco.getRound(latest).endTime ? latest + 1 : latest;
        vm.prank(who);
        fresco.bid(target, amount, BRIEF);
    }

    function _commission() internal returns (bytes32 id) {
        _bid(alice, 1 ether);
        vm.warp(fresco.getRound(1).endTime);
        fresco.settle(1);
        id = fresco.getRound(1).requestId;
    }

    function _image() internal view returns (bytes memory) {
        return vm.readFileBinary("test/fixtures/image-23e66772.canonical.json");
    }

    function _deliver(bytes32 id, bytes memory json) internal {
        vm.prank(address(intake));
        fresco.onResult(id, keccak256(json), "ipfs://x");
    }

    // G01 (M01)
    function testMinRaiseIsExactlyFivePercentRoundedUp() public {
        _bid(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(Sinopia.InvalidBid.selector);
        fresco.bid(1, 1.05 ether - 1, BRIEF);
        _bid(bob, 1.05 ether);
    }

    // G02 (M02)
    function testFreshRoundBelowReserveReverts() public {
        vm.prank(alice);
        vm.expectRevert(Sinopia.InvalidBid.selector);
        fresco.bid(1, 0.55 ether - 1, BRIEF);
    }

    // G03 (M03)
    function testFeeOnTransferTokenIsRejected() public {
        FeeIMD fee = new FeeIMD();
        Sinopia f = new Sinopia(address(intake), address(fee));
        fee.mint(alice, 10 ether);
        vm.prank(alice);
        fee.approve(address(f), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(Sinopia.TransferFailed.selector);
        f.bid(1, 0.55 ether, BRIEF);
    }

    // G04 (M04)
    function testSettleBeforeEndReverts() public {
        _bid(alice, 1 ether);
        vm.expectRevert(Sinopia.InvalidRound.selector);
        fresco.settle(1);
    }

    // G06 (M06)
    function testIntakeReturningZeroOrDuplicateRequestIdReverts() public {
        ConstIntake c = new ConstIntake(imd);
        Sinopia f = new Sinopia(address(c), address(imd));
        vm.prank(alice);
        imd.approve(address(f), type(uint256).max);
        vm.prank(alice);
        f.bid(1, 0.55 ether, BRIEF);
        vm.warp(f.getRound(1).endTime);
        c.set(bytes32(0));
        vm.expectRevert(Sinopia.InvalidResult.selector);
        f.settle(1);
        c.set(bytes32(uint256(7)));
        f.settle(1);
        vm.prank(alice);
        f.bid(2, 0.55 ether, BRIEF);
        vm.warp(f.getRound(2).endTime);
        vm.expectRevert(Sinopia.InvalidResult.selector);
        f.settle(2);
    }

    // G07 (M07)
    function testOnFailureOnlyFromIntakeAndOnlyForKnownCommissionedRequest() public {
        bytes32 id = _commission();
        vm.expectRevert(Sinopia.Unauthorized.selector);
        fresco.onFailure(id, 1, bytes32("x"), 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(Sinopia.InvalidRound.selector);
        fresco.onFailure(bytes32(uint256(999)), 1, bytes32("x"), 0, 0, "");
    }

    // G08 (M08)
    function testRevealRejectsJsonWhoseHashDiffers() public {
        bytes32 id = _commission();
        _deliver(id, _image());
        bytes memory alt = bytes(
            '{"complete":true,"files":[{"hash":"b0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309","mediaType":"image/png","name":"image"}],"jobId":"23e66772-0986-4e80-b7f2-cd1882f5e634","state":"completed"}'
        );
        vm.expectRevert(Sinopia.InvalidResult.selector);
        fresco.reveal(1, alt);
    }

    // G09 (M09)
    function testRejectDeliveryRejectsJsonWhoseHashDiffers() public {
        bytes32 id = _commission();
        _deliver(id, _image());
        bytes memory report = vm.readFileBinary("test/fixtures/report-0e288a21.result.json");
        vm.expectRevert(Sinopia.InvalidResult.selector);
        fresco.rejectDelivery(1, report);
    }

    // G10 (M10)
    function testDeliveredCannotExpireBeforeRevealTimeout() public {
        bytes32 id = _commission();
        _deliver(id, _image());
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Sinopia.InvalidRound.selector);
        fresco.expire(1);
    }

    // G11 (M11)
    function testCancelBeforeGraceReverts() public {
        _bid(alice, 1 ether);
        vm.warp(fresco.getRound(1).endTime + 1 days - 1);
        vm.expectRevert(Sinopia.InvalidRound.selector);
        fresco.cancelUnsettled(1);
    }

    // G12 (M12)
    function testClaimWithNothingPendingReverts() public {
        vm.prank(alice);
        vm.expectRevert(Sinopia.NothingToClaim.selector);
        fresco.claim();
    }

    // G15 + G16 (M15, M16): the whole charset and the length bounds, byte by byte
    function testBriefCharsetAndLengthExact() public view {
        bytes memory allowed = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,!?'-:;()&/");
        for (uint256 b; b < 256; ++b) {
            bool expected;
            for (uint256 i; i < allowed.length; ++i) {
                if (uint8(allowed[i]) == b) expected = true;
            }
            bytes memory s = bytes("aaaaaaa?");
            s[7] = bytes1(uint8(b));
            assertEq(fresco.validBrief(string(s)), expected, "charset");
        }
        assertFalse(fresco.validBrief(string(new bytes(7))));
        assertTrue(fresco.validBrief(string(_rep("a", 8))));
        assertTrue(fresco.validBrief(string(_rep("a", 200))));
        assertFalse(fresco.validBrief(string(_rep("a", 201))));
    }

    function _rep(bytes1 c, uint256 n) internal pure returns (bytes memory r) {
        r = new bytes(n);
        for (uint256 i; i < n; ++i) {
            r[i] = c;
        }
    }

    // G17 (M17)
    function testCommissionedCannotExpireBeforeDeliveryTimeout() public {
        _commission();
        vm.warp(fresco.getRound(1).settledAt + 3 days);
        vm.expectRevert(Sinopia.InvalidRound.selector);
        fresco.expire(1);
    }
}
