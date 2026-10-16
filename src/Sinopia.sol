// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ResultJson} from "./ResultJson.sol";

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

/// @notice Each NFT is minted only by reveal() for a settled and delivered commission, to that round's winner.
/// @dev Token ID is the round ID. There is no owner, admin or other mint path; this NFT is not post-launch token-supply minting.
contract Sinopia is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Commissioned,
        Delivered,
        Revealed,
        Failed,
        Expired,
        Cancelled
    }

    struct Round {
        Status status;
        address bidder;
        uint256 amount;
        uint256 endTime;
        uint256 settledAt;
        uint256 deliveredAt;
        bytes32 requestId;
        bytes32 resultHash;
        bytes32 imageHash;
        string jobId;
        string brief;
        bool refunded;
    }

    bytes32 public constant ACTION = "job.open@job-1";
    uint256 public constant JOB_PRICE = 0.5 ether;
    uint256 public constant RESERVE = 0.55 ether;
    uint256 public constant MIN_RAISE_BPS = 500;
    uint256 public constant DURATION = 3 hours;
    uint256 public constant EXTENSION = 5 minutes;
    uint256 public constant SETTLE_GRACE = 1 days;
    uint256 public constant DELIVERY_TIMEOUT = 3 days;
    uint256 public constant REVEAL_TIMEOUT = 7 days;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    string public constant IMAGE_BASE = "https://api.imd.fun/artifacts/";

    IIntake public immutable intake;
    IERC20 public immutable imd;
    uint256 public latestRoundId;
    uint256 public escrowed;
    mapping(uint256 => Round) private rounds;
    mapping(bytes32 => uint256) public requestRound;
    mapping(address => uint256) public pending;

    event RoundStarted(uint256 indexed roundId, uint256 endTime);
    event BidPlaced(uint256 indexed roundId, address indexed bidder, uint256 amount, string brief, uint256 endTime);
    event Settled(uint256 indexed roundId, address indexed winner, uint256 amount, bytes32 requestId);
    event Delivered(uint256 indexed roundId, bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Revealed(uint256 indexed roundId, bytes32 imageHash, string jobId, uint256 burned);
    event CommissionFailed(uint256 indexed roundId, uint8 status, bytes32 reason);
    event DeliveryRejected(uint256 indexed roundId);
    event Expired(uint256 indexed roundId);
    event Cancelled(uint256 indexed roundId);
    event Refunded(uint256 indexed roundId, address indexed to, uint256 amount);
    event Credited(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    error InvalidBid();
    error InvalidRound();
    error InvalidResult();
    error Unauthorized();
    error TransferFailed();
    error RoundMismatch();
    error NothingToClaim();

    constructor(address intake_, address imd_) ERC721("Sinopia", "SINOPIA") {
        intake = IIntake(intake_);
        imd = IERC20(imd_);
    }

    /// @notice Bids IMD on a specific round, opening it if the previous round has ended.
    function bid(uint256 roundId, uint256 amount, string calldata brief) external nonReentrant {
        uint256 latest = latestRoundId;
        bool fresh = latest == 0 || rounds[latest].status != Status.Open || block.timestamp >= rounds[latest].endTime;
        if (roundId != latest + (fresh ? 1 : 0)) revert RoundMismatch();
        if (!_validBrief(brief)) revert InvalidBid();
        if (fresh) {
            if (amount < RESERVE) revert InvalidBid();
            latestRoundId = roundId;
            Round storage opened = rounds[roundId];
            opened.status = Status.Open;
            opened.endTime = block.timestamp + DURATION;
            emit RoundStarted(roundId, opened.endTime);
        } else {
            uint256 minimum = (rounds[roundId].amount * (10000 + MIN_RAISE_BPS) + 9999) / 10000;
            if (amount < RESERVE || amount < minimum) revert InvalidBid();
        }

        Round storage round = rounds[roundId];
        address previousBidder = round.bidder;
        uint256 previousAmount = round.amount;
        round.bidder = msg.sender;
        round.amount = amount;
        round.brief = brief;
        if (round.endTime - block.timestamp < EXTENSION) round.endTime = block.timestamp + EXTENSION;
        escrowed += amount;
        uint256 beforeBalance = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), amount);
        if (imd.balanceOf(address(this)) - beforeBalance != amount) revert TransferFailed();
        if (!fresh) _refund(roundId, previousBidder, previousAmount);
        emit BidPlaced(roundId, msg.sender, amount, brief, round.endTime);
    }

    /// @notice Commissions the ended round through IMD Intake for exactly 0.5 IMD.
    function settle(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Open || block.timestamp < round.endTime) revert InvalidRound();
        round.status = Status.Commissioned;
        round.settledAt = block.timestamp;
        escrowed -= JOB_PRICE;
        imd.forceApprove(address(intake), JOB_PRICE);
        bytes32 requestId = intake.requestWithFailure(
            ACTION,
            _body(roundId, round.brief),
            IIntake.Callback(address(this), this.onResult.selector),
            this.onFailure.selector,
            address(imd),
            JOB_PRICE
        );
        if (requestId == bytes32(0) || requestRound[requestId] != 0) revert InvalidResult();
        round.requestId = requestId;
        requestRound[requestId] = roundId;
        emit Settled(roundId, round.bidder, round.amount, requestId);
    }

    /// @notice Records the Intake delivery without storing its URI in contract storage.
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external {
        if (msg.sender != address(intake)) revert Unauthorized();
        uint256 roundId = requestRound[requestId];
        if (roundId == 0 || rounds[roundId].status != Status.Commissioned) revert InvalidRound();
        Round storage round = rounds[roundId];
        round.resultHash = resultHash;
        round.deliveredAt = block.timestamp;
        round.status = Status.Delivered;
        emit Delivered(roundId, requestId, resultHash, uri);
    }

    /// @notice Records an unsigned Intake failure; no IMD moves in this callback.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        if (msg.sender != address(intake)) revert Unauthorized();
        uint256 roundId = requestRound[requestId];
        if (roundId == 0 || rounds[roundId].status != Status.Commissioned) revert InvalidRound();
        rounds[roundId].status = Status.Failed;
        emit CommissionFailed(roundId, status, reason);
    }

    /// @notice Mints the delivered artwork NFT to the winning bidder after a hash-checked reveal.
    /// @dev This is the only mint path; token IDs equal round IDs and no admin can change supply.
    function reveal(uint256 roundId, bytes calldata resultJson) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Delivered || keccak256(resultJson) != round.resultHash) revert InvalidResult();
        (bool valid, bytes32 imageHash, string memory jobId,) = ResultJson.parse(resultJson);
        if (!valid) revert InvalidResult();
        round.status = Status.Revealed;
        round.imageHash = imageHash;
        round.jobId = jobId;
        escrowed -= round.amount - JOB_PRICE;
        _mint(round.bidder, roundId);
        imd.safeTransfer(BURN, round.amount - JOB_PRICE);
        emit Revealed(roundId, imageHash, jobId, round.amount - JOB_PRICE);
    }

    /// @notice Marks a hash-checked delivery refundable if its image entry or completion markers are missing.
    function rejectDelivery(uint256 roundId, bytes calldata resultJson) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Delivered || keccak256(resultJson) != round.resultHash) revert InvalidResult();
        (,,, bool rejectable) = ResultJson.parse(resultJson);
        if (!rejectable) revert InvalidResult();
        round.status = Status.Failed;
        emit DeliveryRejected(roundId);
    }

    /// @notice Expires a commission without delivery or an unrevealed delivery after its timeout.
    function expire(uint256 roundId) external {
        Round storage round = rounds[roundId];
        bool timedOut = (round.status == Status.Commissioned && block.timestamp > round.settledAt + DELIVERY_TIMEOUT)
            || (round.status == Status.Delivered && block.timestamp > round.deliveredAt + REVEAL_TIMEOUT);
        if (!timedOut) revert InvalidRound();
        round.status = Status.Expired;
        emit Expired(roundId);
    }

    /// @notice Returns the winning amount less the Intake charge after failure or expiry.
    function claimRefund(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if ((round.status != Status.Failed && round.status != Status.Expired) || round.refunded) revert InvalidRound();
        round.refunded = true;
        _refund(roundId, round.bidder, round.amount - JOB_PRICE);
    }

    /// @notice Cancels an uncommissioned round after its settlement grace period.
    function cancelUnsettled(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status != Status.Open || block.timestamp < round.endTime + SETTLE_GRACE) revert InvalidRound();
        round.status = Status.Cancelled;
        round.refunded = true;
        _refund(roundId, round.bidder, round.amount);
        emit Cancelled(roundId);
    }

    /// @notice Pulls IMD credited after a push refund failed.
    function claim() external nonReentrant {
        uint256 amount = pending[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pending[msg.sender] = 0;
        escrowed -= amount;
        imd.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Returns the complete state of a round.
    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /// @notice Returns the exact compact JSON sent to Intake for a round.
    function bodyFor(uint256 roundId) external view returns (bytes memory) {
        if (rounds[roundId].status == Status.None) revert InvalidRound();
        return _body(roundId, rounds[roundId].brief);
    }

    /// @notice Previews the exact compact JSON for a proposed round and brief.
    function previewBody(uint256 roundId, string calldata brief) external pure returns (bytes memory) {
        if (!_validBrief(brief)) revert InvalidBid();
        return _body(roundId, brief);
    }

    /// @notice Checks the restricted byte charset accepted in a brief.
    function validBrief(string calldata brief) external pure returns (bool) {
        return _validBrief(brief);
    }

    /// @notice Returns metadata for a revealed fresco NFT.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Round storage round = rounds[tokenId];
        bytes memory hashHex = bytes(Strings.toHexString(uint256(round.imageHash), 32));
        bytes memory imageHex = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            imageHex[i] = hashHex[i + 2];
        }
        string memory title = string.concat("Sinopia #", Strings.toString(tokenId));
        string memory json = string.concat(
            '{"name":"',
            title,
            '","description":"',
            round.brief,
            unicode' — painted by the IMD swarm, commissioned onchain by the Sinopia auction.","image":"',
            IMAGE_BASE,
            string(imageHex),
            '","external_url":"https://explorer.imd.fun/jobs/',
            round.jobId,
            '","attributes":[{"trait_type":"Round","value":"',
            Strings.toString(tokenId),
            '"},{"trait_type":"Winning bid (IMD, 2 decimals)","value":"',
            _twoDecimals(round.amount),
            '"},{"trait_type":"IMD burned","value":"',
            _twoDecimals(round.amount - JOB_PRICE),
            '"},{"trait_type":"Job","value":"',
            round.jobId,
            '"},{"trait_type":"Result hash","value":"',
            Strings.toHexString(uint256(round.resultHash), 32),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _validBrief(string calldata brief) private pure returns (bool) {
        bytes calldata chars = bytes(brief);
        if (chars.length < 8 || chars.length > 200) return false;
        bool hasLetter;
        for (uint256 i; i < chars.length; ++i) {
            bytes1 c = chars[i];
            if ((c >= "A" && c <= "Z") || (c >= "a" && c <= "z")) hasLetter = true;
            if (
                (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == " " || c == "."
                    || c == "," || c == "!" || c == "?" || c == "'" || c == "-" || c == ":" || c == ";" || c == "("
                    || c == ")" || c == "&" || c == "/"
            ) continue;
            return false;
        }
        return hasLetter;
    }

    function _body(uint256 roundId, string memory brief) private pure returns (bytes memory) {
        return bytes(
            string.concat(
                '{"objective":"Sinopia #',
                Strings.toString(roundId),
                ". Paint one original artwork in true fresco style: mineral pigment on wet lime plaster, visible plaster texture and fine cracks, warm earth palette with lapis blue accents. Subject, chosen by the collector who won the auction: ",
                brief,
                '. Square 1:1 composition. No text, letters, logos, watermarks or real people.","skill":"create-image","outputs":[{"name":"image","path":"artifacts/image.png","mediaType":"image/png"}],"github":false}'
            )
        );
    }

    function _refund(uint256 roundId, address to, uint256 amount) private {
        (bool success, bytes memory result) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (success && (result.length == 0 || (result.length >= 32 && abi.decode(result, (bool))))) {
            escrowed -= amount;
            emit Refunded(roundId, to, amount);
        } else {
            pending[to] += amount;
            emit Credited(to, amount);
        }
    }

    function _twoDecimals(uint256 amount) private pure returns (string memory) {
        uint256 cents = amount / 1e16;
        uint256 fraction = cents % 100;
        return string.concat(Strings.toString(cents / 100), ".", fraction < 10 ? "0" : "", Strings.toString(fraction));
    }
}
