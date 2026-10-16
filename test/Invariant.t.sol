// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Stateful escrow and transition invariants.
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sinopia, IIntake} from "../src/Sinopia.sol";

contract BlockableIMD is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    // push refunds to a blocked recipient fail with `false`, exercising the pending-credit path
    function transfer(address to, uint256 a) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, a);
    }
}

contract SeqIntake is IIntake {
    IERC20 public immutable imd;
    uint256 public count;
    bool public fail;

    constructor(IERC20 i) {
        imd = i;
    }

    function setFail(bool v) external {
        fail = v;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address, uint256 amount)
        external
        returns (bytes32)
    {
        if (fail) revert("down");
        imd.transferFrom(msg.sender, address(this), amount);
        return bytes32(++count);
    }
}

contract Handler is Test {
    Sinopia public s;
    BlockableIMD public imd;
    SeqIntake public intake;
    address[3] public actors = [address(0xA1), address(0xB2), address(0xC3)];
    bytes public ok;
    bytes public noImg;
    string constant BRIEF = "A blue river over warm hills";
    mapping(uint256 => uint8) public seen;
    bool public illegalTransition;
    uint256 public supply;

    constructor() {
        imd = new BlockableIMD();
        intake = new SeqIntake(imd);
        s = new Sinopia(address(intake), address(imd));
        ok = vm.readFileBinary("test/fixtures/image-23e66772.canonical.json");
        noImg = vm.readFileBinary("test/fixtures/report-0e288a21.result.json");
        for (uint256 i; i < 3; ++i) {
            imd.mint(actors[i], 1000 ether);
            supply += 1000 ether;
            vm.prank(actors[i]);
            imd.approve(address(s), type(uint256).max);
        }
        imd.mint(address(s), 3 ether); // stray donation: must never be spent or counted as escrow
        supply += 3 ether;
    }

    function _rid(uint256 seed) internal view returns (uint256) {
        uint256 n = s.latestRoundId();
        return n == 0 ? 0 : 1 + (seed % n);
    }

    function _a(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    // legal transitions: None>Open; Open>Commissioned|Cancelled; Commissioned>Delivered|Failed|Expired;
    // Delivered>Revealed|Failed|Expired. Everything else is illegal.
    function _legal(uint8 a, uint8 b) internal pure returns (bool) {
        if (a == b) return true;
        if (a == 0) return b == 1;
        if (a == 1) return b == 2 || b == 7;
        if (a == 2) return b == 3 || b == 5 || b == 6;
        if (a == 3) return b == 4 || b == 5 || b == 6;
        return false;
    }

    function _track() internal {
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            uint8 cur = uint8(s.getRound(i).status);
            if (!_legal(seen[i], cur)) illegalTransition = true;
            seen[i] = cur;
        }
    }

    function bid(uint256 who, uint256 amt) external {
        amt = bound(amt, 0.55 ether, 4 ether);
        vm.prank(_a(who));
        uint256 latest = s.latestRoundId();
        uint256 target = latest == 0 || block.timestamp >= s.getRound(latest).endTime ? latest + 1 : latest;
        try s.bid(target, amt, BRIEF) {} catch {}
        _track();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
        _track();
    }

    function settle(uint256 r) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.settle(id) {} catch {}
        _track();
    }

    function _deliver(uint256 r, bytes memory j) internal {
        uint256 id = _rid(r);
        if (id == 0) return;
        bytes32 req = s.getRound(id).requestId;
        vm.prank(address(intake));
        try s.onResult(req, keccak256(j), "u") {} catch {}
        _track();
    }

    function deliverOk(uint256 r) external {
        _deliver(r, ok);
    }

    function deliverNoImage(uint256 r) external {
        _deliver(r, noImg);
    }

    function deliverGarbage(uint256 r) external {
        _deliver(r, hex"01");
    }

    function failRound(uint256 r) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        bytes32 req = s.getRound(id).requestId;
        vm.prank(address(intake));
        try s.onFailure(req, 2, bytes32("x"), 0, 0, "") {} catch {}
        _track();
    }

    function reveal(uint256 r, bool useOk) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.reveal(id, useOk ? ok : noImg) {} catch {}
        _track();
    }

    function reject(uint256 r, bool useOk) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.rejectDelivery(id, useOk ? ok : noImg) {} catch {}
        _track();
    }

    function expire(uint256 r) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.expire(id) {} catch {}
        _track();
    }

    function claimRefund(uint256 r) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.claimRefund(id) {} catch {}
        _track();
    }

    function cancel(uint256 r) external {
        uint256 id = _rid(r);
        if (id == 0) return;
        try s.cancelUnsettled(id) {} catch {}
        _track();
    }

    function claim(uint256 who) external {
        vm.prank(_a(who));
        try s.claim() {} catch {}
        _track();
    }

    function setBlocked(uint256 who, bool on) external {
        imd.setBlocked(_a(who), on);
    }

    function intakeDown(bool v) external {
        intake.setFail(v);
    }
}

contract InvariantSinopia is StdInvariant, Test {
    Handler h;
    Sinopia s;
    BlockableIMD imd;
    SeqIntake intake;

    function setUp() public {
        h = new Handler();
        s = h.s();
        imd = h.imd();
        intake = h.intake();
        targetContract(address(h));
    }

    function invariant_solvent() public view {
        assertGe(imd.balanceOf(address(s)), s.escrowed());
    }

    // the contract's balance is exactly its tracked escrow plus the untouched stray donation
    function invariant_balanceEqualsEscrowPlusDonation() public view {
        assertEq(imd.balanceOf(address(s)) - s.escrowed(), 3 ether);
    }

    function invariant_escrowEqualsSumOfObligations() public view {
        uint256 owed;
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            Sinopia.Round memory r = s.getRound(i);
            if (r.status == Sinopia.Status.Open) {
                owed += r.amount;
            } else if (r.status == Sinopia.Status.Commissioned || r.status == Sinopia.Status.Delivered) {
                owed += r.amount - 0.5 ether;
            } else if ((r.status == Sinopia.Status.Failed || r.status == Sinopia.Status.Expired) && !r.refunded) {
                owed += r.amount - 0.5 ether;
            }
        }
        for (uint256 j; j < 3; ++j) {
            owed += s.pending(h.actors(j));
        }
        assertEq(s.escrowed(), owed);
    }

    function invariant_noValueLeaksOutOfTheClosedSystem() public view {
        uint256 total = imd.balanceOf(address(s)) + imd.balanceOf(address(intake)) + imd.balanceOf(s.BURN());
        for (uint256 j; j < 3; ++j) {
            total += imd.balanceOf(h.actors(j));
        }
        assertEq(total, h.supply());
    }

    function invariant_intakeReceivedExactlyJobPricePerSettledRound() public view {
        uint256 settled;
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            if (s.getRound(i).settledAt != 0) ++settled;
        }
        assertEq(imd.balanceOf(address(intake)), settled * 0.5 ether);
    }

    function invariant_burnAndNftSupplyMatchRevealedRounds() public view {
        uint256 burned;
        uint256 minted;
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            Sinopia.Round memory r = s.getRound(i);
            bool revealed = r.status == Sinopia.Status.Revealed;
            if (revealed) {
                burned += r.amount - 0.5 ether;
                ++minted;
            }
            try s.ownerOf(i) returns (address o) {
                assertTrue(revealed, "token exists for a non-revealed round");
                assertEq(o, r.bidder, "token not held by the winner");
            } catch {
                assertFalse(revealed, "revealed round has no token");
            }
        }
        assertEq(imd.balanceOf(s.BURN()), burned);
        uint256 held;
        for (uint256 j; j < 3; ++j) {
            held += s.balanceOf(h.actors(j));
        }
        assertEq(held, minted);
    }

    function invariant_onlyLegalStatusTransitions() public view {
        assertFalse(h.illegalTransition());
    }

    // Liveness: after any reachable history, letting every timer run out and calling only permissionless
    // functions returns every escrowed unit to its owner. Nothing stays locked.
    function afterInvariant() public {
        imd.setBlocked(h.actors(0), false);
        imd.setBlocked(h.actors(1), false);
        imd.setBlocked(h.actors(2), false);
        vm.warp(block.timestamp + 30 days);
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            try s.cancelUnsettled(i) {} catch {}
            try s.expire(i) {} catch {}
            try s.claimRefund(i) {} catch {}
        }
        for (uint256 j; j < 3; ++j) {
            vm.prank(h.actors(j));
            try s.claim() {} catch {}
        }
        assertEq(s.escrowed(), 0, "funds still escrowed after every timer expired");
        assertEq(imd.balanceOf(address(s)), 3 ether, "only the stray donation remains");
        for (uint256 i = 1; i <= n; ++i) {
            Sinopia.Round memory r = s.getRound(i);
            assertTrue(
                r.status == Sinopia.Status.Revealed || r.status == Sinopia.Status.Cancelled
                    || ((r.status == Sinopia.Status.Failed || r.status == Sinopia.Status.Expired) && r.refunded),
                "round not terminal after all timers"
            );
        }
    }

    function invariant_atMostOneLiveOpenRoundAndItIsTheLatest() public view {
        uint256 live;
        uint256 n = s.latestRoundId();
        for (uint256 i = 1; i <= n; ++i) {
            Sinopia.Round memory r = s.getRound(i);
            if (r.status == Sinopia.Status.Open && block.timestamp < r.endTime) {
                ++live;
                assertEq(i, n);
            }
        }
        assertLe(live, 1);
    }
}

