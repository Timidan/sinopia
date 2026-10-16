// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Reviewer robustness probes.
import {Test} from "forge-std/Test.sol";
import {Sinopia} from "../src/Sinopia.sol";
import {ResultJson} from "../src/ResultJson.sol";
import {MockIMD, MockIntake} from "./Sinopia.t.sol";

contract ParserHarness {
    function parse(bytes calldata d) external pure returns (bool, bytes32, string memory, bool) {
        return ResultJson.parse(d);
    }
}

contract ExtraTest is Test {
    ParserHarness h = new ParserHarness();
    MockIMD imd;
    MockIntake intake;
    Sinopia fresco;
    address alice = address(0xA11CE);

    function setUp() public {
        imd = new MockIMD();
        intake = new MockIntake(imd);
        fresco = new Sinopia(address(intake), address(imd));
        imd.mint(alice, 1000 ether);
        vm.prank(alice);
        imd.approve(address(fresco), type(uint256).max);
    }

    function _img() internal view returns (bytes memory) {
        return vm.readFileBinary("test/fixtures/image-23e66772.canonical.json");
    }

    // P1: parse never reverts on any prefix of a real result (so rejectDelivery can always classify authenticated garbage)
    function testParserTruncationsNeverRevert() public view {
        bytes memory img = _img();
        uint256 validCount;

        for (uint256 n; n <= img.length; ++n) {
            bytes memory t = new bytes(n);
            for (uint256 i; i < n; ++i) {
                t[i] = img[i];
            }
            (bool ok,,,) = h.parse(t);
            if (ok) ++validCount;
        }
        assertEq(validCount, 1, "only the complete document is valid");
    }

    // P2: sample byte flips through the fixture without exhausting the test gas limit
    function testParserByteFlipsNeverRevert() public {
        bytes memory img = _img();
        bytes memory repl = bytes('"{}x');
        uint256 calls;
        uint256 validAfterFlip;
        for (uint256 p; p < img.length; p += 23) {
            for (uint256 r; r < repl.length; ++r) {
                bytes memory m = img;
                m = abi.encodePacked(m);
                m[p] = repl[r];
                (bool ok,,,) = h.parse(m);
                if (ok) ++validAfterFlip;
                ++calls;
            }
        }
        emit log_named_uint("flip parses", calls);
        emit log_named_uint("flips that still parse as valid image", validAfterFlip);
    }

    function testFuzz_parseNeverRevertsOnArbitraryBytes(bytes calldata d) public view {
        h.parse(d);
    }

    function testFuzz_parseNeverRevertsOnMutatedFixture(uint16 p1, uint8 b1, uint16 p2, uint8 b2, uint16 cut)
        public
        view
    {
        bytes memory img = _img();
        bytes memory m = new bytes(bound(cut, 0, img.length));
        for (uint256 i; i < m.length; ++i) {
            m[i] = img[i];
        }
        if (m.length > 0) {
            m[p1 % m.length] = bytes1(b1);
            m[p2 % m.length] = bytes1(b2);
        }
        h.parse(m);
    }

    // P3: for any brief the contract accepts, the Intake body and the token metadata are valid JSON that carry the brief
    function testFuzz_bodyAndMetadataAreValidJson(uint256 seed, uint8 lenSeed) public {
        bytes memory allowed = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,!?'-:;()&/");
        uint256 len = 8 + (uint256(lenSeed) % 193);
        bytes memory b = new bytes(len);
        b[0] = "A";
        for (uint256 i = 1; i < len; ++i) {
            b[i] = allowed[uint256(keccak256(abi.encode(seed, i))) % allowed.length];
        }
        string memory brief = string(b);
        assertTrue(fresco.validBrief(brief));
        bytes memory body = fresco.previewBody(1, brief);
        string memory objective = vm.parseJsonString(string(body), ".objective");
        assertGt(bytes(objective).length, len);
        assertEq(vm.parseJsonString(string(body), ".skill"), "create-image");
        assertEq(vm.parseJsonString(string(body), ".outputs[0].name"), "image");

        vm.prank(alice);
        fresco.bid(1, 0.55 ether, brief);
        vm.warp(fresco.getRound(1).endTime);
        fresco.settle(1);
        assertEq(intake.lastBody(), body);
        bytes memory json = _img();
        bytes32 rid = fresco.getRound(1).requestId;
        vm.prank(address(intake));
        fresco.onResult(rid, keccak256(json), "ipfs://x");
        fresco.reveal(1, json);
        string memory uri = fresco.tokenURI(1);
        bytes memory enc = bytes(uri);
        bytes memory payload = new bytes(enc.length - 29);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = enc[i + 29];
        }
        string memory meta = string(_b64(payload));
        assertEq(vm.parseJsonString(meta, ".name"), "Sinopia #1");
        assertEq(
            vm.parseJsonString(meta, ".image"),
            "https://api.imd.fun/artifacts/a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309"
        );
        assertEq(vm.parseJsonString(meta, ".attributes[1].value"), "0.55");
        assertEq(vm.parseJsonString(meta, ".attributes[2].value"), "0.05");
        string memory desc = vm.parseJsonString(meta, ".description");
        assertEq(
            keccak256(bytes(desc)),
            keccak256(
                abi.encodePacked(
                    brief, unicode" — painted by the IMD swarm, commissioned onchain by the Sinopia auction."
                )
            )
        );
    }

    // P4: gas of parse() grows with document size (images last, N extra flat non-image files first)
    function testParseGasScaling() public {
        bytes memory head = bytes(
            '{"complete":true,"delivery":{"commit":null,"deliveredAt":null,"failure":null,"mode":"research","repoUrl":null,"requested":false},"files":['
        );
        bytes memory filler = bytes(
            '{"bytes":4835,"evaluation":"structural","hash":"db22326972784522a02105217cb8e0bbd249fb30acc5161b4737d579a18e8487","mediaType":"text/markdown","name":"report","path":"artifacts/report.md","profile":"none","submissionHash":"4b42acefe9447b95f0af25307c2074e48c399ff1d05d7b9b15d073416da7a878","url":"https://api.imd.fun/artifacts/db22326972784522a02105217cb8e0bbd249fb30acc5161b4737d579a18e8487"},'
        );
        bytes memory image = bytes(
            '{"bytes":3210718,"evaluation":"structural","hash":"a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309","mediaType":"image/png","name":"image","path":"artifacts/image.png","profile":"none","submissionHash":"fcdd34e22754fafef4151e69527b18eceaa1d45f65fb30f048e5eb3c0bf8cf68","url":"https://api.imd.fun/artifacts/a0caa7dcf140dc65ac5c606be9151dac6c7f00d021e288646a596c96c6ce5309"}'
        );
        bytes memory tail = bytes(
            '],"jobId":"23e66772-0986-4e80-b7f2-cd1882f5e634","launch":{"chainId":null,"id":null,"kind":null,"requested":false,"status":null},"projectId":"23e66772-0986-4e80-b7f2-cd1882f5e634","source":[],"state":"completed"}'
        );
        uint256[5] memory ns = [uint256(0), 1, 5, 20, 60];
        for (uint256 k; k < ns.length; ++k) {
            bytes memory doc = head;
            for (uint256 i; i < ns[k]; ++i) {
                doc = abi.encodePacked(doc, filler);
            }
            doc = abi.encodePacked(doc, image, tail);
            uint256 g = gasleft();
            (bool ok,,,) = h.parse(doc);
            g = g - gasleft();
            emit log_named_uint(string.concat("extra files=", vm.toString(ns[k]), " bytes"), doc.length);
            emit log_named_uint("   parse gas", g);
            assertTrue(ok);
        }
    }

    // P6: parse gas on the two real fixtures (reveal path and reject path)
    function testParseGasOnRealFixtures() public {
        bytes memory img = _img();
        uint256 g = gasleft();
        (bool ok,,,) = h.parse(img);
        g = g - gasleft();
        emit log_named_uint("parse gas, real image result (bytes follow)", g);
        emit log_named_uint("   bytes", img.length);
        assertTrue(ok);
        bytes memory rep = vm.readFileBinary("test/fixtures/report-0e288a21.result.json");
        g = gasleft();
        (bool ok2,,, bool rej) = h.parse(rep);
        g = g - gasleft();
        emit log_named_uint("parse gas, real report result (reject path)", g);
        emit log_named_uint("   bytes", rep.length);
        assertTrue(!ok2 && rej);
    }

    // P5: onResult gas with a long uri (cold slots via isolate-like first call)
    function testOnResultGasLongUri() public {
        vm.prank(alice);
        fresco.bid(1, 0.55 ether, "A blue river over warm hills");
        vm.warp(fresco.getRound(1).endTime);
        fresco.settle(1);
        bytes32 id = fresco.getRound(1).requestId;
        bytes memory uri = new bytes(1000);
        for (uint256 i; i < uri.length; ++i) {
            uri[i] = "u";
        }
        vm.prank(address(intake));
        uint256 g = gasleft();
        (bool ok,) =
            address(fresco).call{gas: 200_000}(abi.encodeCall(Sinopia.onResult, (id, bytes32(uint256(1)), string(uri))));
        emit log_named_uint("onResult gas, 1000-byte uri", g - gasleft());
        assertTrue(ok);
    }

    function _b64(bytes memory encoded) internal pure returns (bytes memory decoded) {
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
