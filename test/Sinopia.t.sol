// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sinopia} from "../src/Sinopia.sol";
import {IIntake} from "../src/Sinopia.sol";
import {ResultJson} from "../src/ResultJson.sol";

contract MockIMD is ERC20 {
    bool public failTransfer;
    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfer(bool value) external {
        failTransfer = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }
}

contract MockIntake is IIntake {
    IERC20 public immutable imd;
    uint256 public count;
    bool public fail;
    bytes public lastBody;

    constructor(IERC20 imd_) {
        imd = imd_;
    }

    function requestWithFailure(bytes32, bytes calldata body, Callback calldata, bytes4, address, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        if (fail) revert("intake unavailable");
        imd.transferFrom(msg.sender, address(this), amount);
        lastBody = body;
        requestId = bytes32(++count);
    }

    function setFail(bool value) external {
        fail = value;
    }
}

contract SinopiaTest is Test {
    event Claimed(address indexed account, uint256 amount);
    event DeliveryRejected(uint256 indexed roundId);
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

    function _settle() internal returns (bytes32) {
        Sinopia.Round memory round = fresco.getRound(1);
        vm.warp(round.endTime);
        fresco.settle(1);
        return fresco.getRound(1).requestId;
    }

    function _image() internal view returns (bytes memory) {
        return vm.readFileBinary("test/fixtures/image-23e66772.canonical.json");
    }

    function _deliver(bytes32 requestId, bytes memory json) internal {
        vm.prank(address(intake));
        fresco.onResult(requestId, keccak256(json), "ipfs://result");
    }

    function testHappyPath() public {
        _bid(alice, 0.55 ether);
        vm.warp(fresco.getRound(1).endTime - 1 minutes);
        _bid(bob, 0.58 ether);
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(fresco.getRound(1).endTime, block.timestamp + 5 minutes);
        bytes32 requestId = _settle();
        assertEq(intake.lastBody(), fresco.bodyFor(1));
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        bytes memory json = _image();
        _deliver(requestId, json);
        uint256 burnBefore = imd.balanceOf(fresco.BURN());
        uint256 gasBefore = gasleft();
        fresco.reveal(1, json);
        emit log_named_uint("fixture reveal gas", gasBefore - gasleft());
        assertEq(fresco.ownerOf(1), bob);
        assertEq(imd.balanceOf(fresco.BURN()) - burnBefore, 0.08 ether);
        assertEq(fresco.escrowed(), 0);
        string memory uri = fresco.tokenURI(1);
        assertTrue(bytes(uri).length > 29);
        bytes memory encoded = bytes(uri);
        bytes memory payload = new bytes(encoded.length - 29);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = encoded[i + 29];
        }
        string memory metadata = string(_decodeBase64(payload));
        assertTrue(_contains(metadata, "Sinopia #1"));
        assertTrue(_contains(metadata, "a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309"));
        assertTrue(_contains(metadata, "23e66772-0986-4e80-b7f2-cd1882f5e634"));
    }

    function testCommissionFailureRefund() public {
        _bid(alice, 0.55 ether);
        bytes32 id = _settle();
        vm.prank(address(intake));
        fresco.onFailure(id, 1, bytes32("refused"), 0, 0, "");
        fresco.claimRefund(1);
        assertEq(imd.balanceOf(alice), 9.5 ether);
        assertEq(fresco.escrowed(), 0);
        vm.expectRevert();
        fresco.claimRefund(1);
    }

    function testRejectDelivery() public {
        _bid(alice, 0.55 ether);
        bytes32 id = _settle();
        bytes memory report = vm.readFileBinary("test/fixtures/report-0e288a21.result.json");
        _deliver(id, report);
        vm.expectEmit(true, false, false, true, address(fresco));
        emit DeliveryRejected(1);
        fresco.rejectDelivery(1, report);
        fresco.claimRefund(1);
        assertEq(imd.balanceOf(alice), 9.5 ether);
    }

    function testExpireAndLateCallback() public {
        _bid(alice, 0.55 ether);
        bytes32 id = _settle();
        vm.warp(block.timestamp + 3 days + 1);
        fresco.expire(1);
        vm.prank(address(intake));
        vm.expectRevert();
        fresco.onResult(id, bytes32(uint256(1)), "uri");
        fresco.claimRefund(1);
        assertEq(fresco.escrowed(), 0);
    }

    function testDeliveredExpiry() public {
        _bid(alice, 0.55 ether);
        bytes32 id = _settle();
        bytes memory malformed = bytes(
            '{"complete":true,"files":[{"hash":"a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309","mediaType":"image/png","name":"image"}],"jobId":"bad","state":"completed"}'
        );
        _deliver(id, malformed);
        vm.expectRevert();
        fresco.rejectDelivery(1, malformed);
        vm.warp(block.timestamp + 7 days + 1);
        fresco.expire(1);
        fresco.claimRefund(1);
        assertEq(fresco.escrowed(), 0);
    }

    function testCancelAndNewRound() public {
        _bid(alice, 0.55 ether);
        uint256 end = fresco.getRound(1).endTime;
        vm.warp(end);
        _bid(bob, 0.55 ether);
        assertEq(fresco.latestRoundId(), 2);
        vm.warp(end + 1 days);
        fresco.cancelUnsettled(1);
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(fresco.escrowed(), 0.55 ether);
    }

    function testIntakeRevertLeavesOpen() public {
        _bid(alice, 0.55 ether);
        intake.setFail(true);
        vm.warp(fresco.getRound(1).endTime);
        vm.expectRevert();
        fresco.settle(1);
        assertEq(uint8(fresco.getRound(1).status), uint8(Sinopia.Status.Open));
        assertEq(fresco.escrowed(), 0.55 ether);
    }

    function testCallbackGuardsAndGas() public {
        _bid(alice, 0.55 ether);
        bytes32 id = _settle();
        vm.expectRevert();
        fresco.onResult(id, bytes32(uint256(1)), "uri");
        vm.prank(address(intake));
        vm.expectRevert();
        fresco.onResult(bytes32(uint256(999)), bytes32(uint256(1)), "uri");
        vm.prank(address(intake));
        (bool ok,) = address(fresco).call{gas: 200_000}(
            abi.encodeCall(Sinopia.onResult, (id, keccak256(_image()), "ipfs://result"))
        );
        assertTrue(ok);
        vm.prank(address(intake));
        vm.expectRevert();
        fresco.onResult(id, bytes32(uint256(1)), "uri");
    }

    function testBriefRulesAndBody() public {
        assertTrue(fresco.validBrief(BRIEF));
        assertFalse(fresco.validBrief("         "));
        assertFalse(fresco.validBrief("short"));
        assertFalse(fresco.validBrief("Bad \"quote\""));
        assertFalse(fresco.validBrief("Bad #hashtag"));
        assertFalse(fresco.validBrief(unicode"Bad é input"));
        vm.expectRevert();
        fresco.previewBody(1, "Bad \"quote\"");
        vm.expectRevert(Sinopia.InvalidBid.selector);
        fresco.previewBody(1, "         ");
        bytes memory body = fresco.previewBody(1, BRIEF);
        assertEq(
            string(body),
            '{"objective":"Sinopia #1. Paint one original artwork in true fresco style: mineral pigment on wet lime plaster, visible plaster texture and fine cracks, warm earth palette with lapis blue accents. Subject, chosen by the collector who won the auction: A blue river over warm hills. Square 1:1 composition. No text, letters, logos, watermarks or real people.","skill":"create-image","outputs":[{"name":"image","path":"artifacts/image.png","mediaType":"image/png"}],"github":false}'
        );
    }

    function testAccountingInvariant() public {
        imd.mint(address(fresco), 7 ether);
        _bid(alice, 0.55 ether);
        assertEq(fresco.escrowed(), 0.55 ether);
        _bid(bob, 0.58 ether);
        assertEq(fresco.escrowed(), 0.58 ether);
        _settle();
        assertEq(fresco.escrowed(), 0.08 ether);
        assertGe(imd.balanceOf(address(fresco)), fresco.escrowed());
    }

    function testPushFallbackBecomesClaimableCredit() public {
        _bid(alice, 0.55 ether);
        imd.setFailTransfer(true);
        _bid(bob, 0.58 ether);
        assertEq(fresco.pending(alice), 0.55 ether);
        assertEq(fresco.escrowed(), 1.13 ether);
        imd.setFailTransfer(false);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(fresco));
        emit Claimed(alice, 0.55 ether);
        fresco.claim();
        assertEq(fresco.pending(alice), 0);
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(fresco.escrowed(), 0.58 ether);
    }

    function testStaleRoundBidAfterEndReverts() public {
        _bid(alice, 0.55 ether);
        vm.warp(fresco.getRound(1).endTime);
        vm.prank(bob);
        vm.expectRevert(Sinopia.RoundMismatch.selector);
        fresco.bid(1, 0.55 ether, BRIEF);
        assertEq(fresco.latestRoundId(), 1);
    }

    function testParserFixturesAndMalformed() public {
        bytes memory image = _image();
        (bool valid, bytes32 hash, string memory job) = this.parse(image);
        assertTrue(valid);
        assertEq(hash, 0xa0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309);
        assertEq(job, "23e66772-0986-4e80-b7f2-cd1882f5e634");
        (valid,,) = this.parse(vm.readFileBinary("test/fixtures/report-08f59d80.result.json"));
        assertFalse(valid);
        (valid,,) = this.parse(
            bytes('{"complete":true,"files":[],"jobId":"23e66772-0986-4e80-b7f2-cd1882f5e634","state":"completed"}')
        );
        assertFalse(valid);
        (valid,,) = this.parse(
            bytes(
                '{"complete":true,"files":[{"hash":"a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309","mediaType":"image/png","name":"image"},{}],"jobId":"23e66772-0986-4e80-b7f2-cd1882f5e634","state":"completed"}'
            )
        );
        assertTrue(valid);
        bytes memory truncated = new bytes(image.length - 5);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = image[i];
        }
        (valid,,) = this.parse(truncated);
        assertFalse(valid);
        (valid,,) = this.parse(
            bytes(
                '{"complete":true,"files":[{"hash":"A0CAA7DCF140DC65AC5C606BE9151DAC6C7F00D021E288646A596C96C6CE5309","mediaType":"image/png","name":"image"}],"jobId":"23e66772-0986-4e80-b7f2-cd1882f5e634","state":"completed"}'
            )
        );
        assertTrue(valid);
    }

    function parse(bytes calldata json) external pure returns (bool, bytes32, string memory) {
        (bool valid, bytes32 hash, string memory jobId,) = ResultJson.parse(json);
        return (valid, hash, jobId);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool same = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    function _decodeBase64(bytes memory encoded) internal pure returns (bytes memory decoded) {
        decoded = new bytes(encoded.length * 3 / 4);
        uint256 out;
        uint256 bits;
        uint256 count;
        for (uint256 i; i < encoded.length; ++i) {
            uint8 c = uint8(encoded[i]);
            if (c == 61) break;
            uint256 value;
            if (c >= 65 && c <= 90) value = c - 65;
            else if (c >= 97 && c <= 122) value = c - 71;
            else if (c >= 48 && c <= 57) value = c + 4;
            else if (c == 43) value = 62;
            else if (c == 47) value = 63;
            else revert("invalid base64");
            bits = (bits << 6) | value;
            count += 6;
            if (count >= 8) {
                count -= 8;
                decoded[out++] = bytes1(uint8(bits >> count));
            }
        }
        assembly { mstore(decoded, out) }
    }
}
