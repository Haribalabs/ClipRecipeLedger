// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ClipRecipeLedger
 * @notice Recipe and pack governance for collaborative funny-video generation (0x_GenV_99 app).
 * @dev Single combined app contract; all outputs in one file.
 */
contract ClipRecipeLedger {
    uint256 public constant MAX_PACK_ENTRIES = 72;
    uint256 public constant MAX_DURATION_SEC = 120;
    uint256 public constant MAX_TITLE_LEN = 128;
    uint256 public constant MAX_RECIPES_CAP = 380_000;
    uint256 public constant MAX_COLLABORATORS = 20;
    uint256 public constant POLL_DURATION = 160;
    uint256 public constant QUORUM_BP = 3600;
    uint256 public constant BPS = 10_000;
    uint256 public constant MUTEX = 1;
    bytes32 public constant APP_NAMESPACE = keccak256("ClipRecipeLedger.0x_GenV_99.v1");
    bytes32 public constant SEED_MAGIC = 0x3e5a7c9d1f2b4e6a8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b;

    address public immutable CONTROLLER;
    address public immutable MODERATOR;
    address public immutable PIPELINE;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable LAUNCH_TS;

    uint256 private _mutex;
    bool public stopped;

    enum RecipeStatus { Empty, Draft, Live, InPoll, Retired }

    struct RecipeData {
        uint256 recipeId;
        address author;
        string title;
        bytes32 packHash;
        bytes32 timelineHash;
        uint32 durationSec;
        uint32 chuckleLevel;
        uint32 mixSeed;
        uint64 createdTs;
        uint64 modifiedTs;
        RecipeStatus status;
    }

    struct PollData {
        uint64 openedTs;
        uint32 approveVotes;
        uint32 rejectVotes;
        bool closed;
        bool approved;
    }

    mapping(uint256 => RecipeData) public recipes;
    mapping(uint256 => bytes32[]) private _packHashes;
    mapping(uint256 => address[]) private _collabList;
    mapping(uint256 => PollData) public polls;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256[]) private _authoredIds;

    uint256 public recipeCounter;

    event RecipeMinted(uint256 indexed recipeId, address indexed author, string title, bytes32 packHash);
    event RecipeEdited(uint256 indexed recipeId, bytes32 timelineHash, uint64 atTs);
    event StatusChanged(uint256 indexed recipeId, RecipeStatus fromStatus, RecipeStatus toStatus, uint64 atTs);
    event CollaboratorJoined(uint256 indexed recipeId, address indexed collaborator, uint64 atTs);
    event PollStarted(uint256 indexed recipeId, uint64 atTs);
    event VoteCast(uint256 indexed recipeId, address indexed voter, bool approve, uint64 atTs);
    event PollClosed(uint256 indexed recipeId, bool approved, uint32 approveVotes, uint32 rejectVotes, uint64 atTs);
    event StoppedSet(bool stopped, uint64 atTs);

    error CRL_NotController();
    error CRL_NotModerator();
    error CRL_NotPipeline();
    error CRL_Unauthorized();
    error CRL_InvalidInput();
    error CRL_InvalidState();
    error CRL_Reentrancy();
    error CRL_Stopped();
    error CRL_NotFound();
    error CRL_CapExceeded();
    error CRL_Already();

    modifier onlyController() { if (msg.sender != CONTROLLER) revert CRL_NotController(); _; }
    modifier onlyModerator() { if (msg.sender != MODERATOR) revert CRL_NotModerator(); _; }
    modifier onlyPipeline() { if (msg.sender != PIPELINE) revert CRL_NotPipeline(); _; }
    modifier nonReentrant() { if (_mutex != 0) revert CRL_Reentrancy(); _mutex = MUTEX; _; _mutex = 0; }
    modifier whenRunning() { if (stopped) revert CRL_Stopped(); _; }

    constructor() {
        CONTROLLER = msg.sender;
        MODERATOR = 0xB4c5D6e7F8a9B0c1D2e3F4a5B6c7D8e9F0a1B2c3;
        PIPELINE = 0xD6e7F8a9B0c1D2e3F4a5B6c7D8e9F0a1B2c3D4e5;
        FEE_RECIPIENT = 0xF0a1B2c3D4e5F6a7B8c9D0e1F2a3B4c5D6e7F8a9;
        LAUNCH_TS = block.timestamp;
    }

    function createRecipe(
        string calldata title,
        bytes32 packHash,
        bytes32 timelineHash,
        uint32 durationSec,
        uint32 chuckleLevel,
        uint32 mixSeed,
        bytes32[] calldata packEntries,
        address[] calldata collaborators
    ) external whenRunning nonReentrant returns (uint256 recipeId) {
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_LEN) revert CRL_InvalidInput();
        if (packHash == bytes32(0) || timelineHash == bytes32(0)) revert CRL_InvalidInput();
        if (durationSec == 0 || durationSec > MAX_DURATION_SEC) revert CRL_InvalidInput();
        if (packEntries.length == 0 || packEntries.length > MAX_PACK_ENTRIES) revert CRL_InvalidInput();
        if (collaborators.length > MAX_COLLABORATORS) revert CRL_InvalidInput();
        if (recipeCounter >= MAX_RECIPES_CAP) revert CRL_CapExceeded();
        recipeId = ++recipeCounter;
        recipes[recipeId] = RecipeData({
            recipeId: recipeId,
            author: msg.sender,
            title: title,
            packHash: packHash,
            timelineHash: timelineHash,
            durationSec: durationSec,
            chuckleLevel: chuckleLevel,
            mixSeed: mixSeed,
            createdTs: uint64(block.timestamp),
            modifiedTs: uint64(block.timestamp),
            status: RecipeStatus.Draft
        });
        for (uint256 i = 0; i < packEntries.length; i++) {
            if (packEntries[i] == bytes32(0)) revert CRL_InvalidInput();
            _packHashes[recipeId].push(packEntries[i]);
        }
        for (uint256 j = 0; j < collaborators.length; j++) {
            if (collaborators[j] == address(0)) revert CRL_InvalidInput();
            _collabList[recipeId].push(collaborators[j]);
            emit CollaboratorJoined(recipeId, collaborators[j], uint64(block.timestamp));
        }
        _authoredIds[msg.sender].push(recipeId);
        emit RecipeMinted(recipeId, msg.sender, title, packHash);
    }

    function updateTimeline(uint256 recipeId, bytes32 newTimelineHash, uint32 newChuckleLevel) external whenRunning {
        RecipeData storage r = recipes[recipeId];
        if (r.recipeId == 0) revert CRL_NotFound();
        if (msg.sender != r.author && msg.sender != PIPELINE) revert CRL_Unauthorized();
        if (r.status == RecipeStatus.Retired) revert CRL_InvalidState();
        if (newTimelineHash == bytes32(0)) revert CRL_InvalidInput();
        r.timelineHash = newTimelineHash;
        r.chuckleLevel = newChuckleLevel;
        r.modifiedTs = uint64(block.timestamp);
        emit RecipeEdited(recipeId, newTimelineHash, uint64(block.timestamp));
    }

    function setStatus(uint256 recipeId, RecipeStatus newStatus) external whenRunning {
        RecipeData storage r = recipes[recipeId];
        if (r.recipeId == 0) revert CRL_NotFound();
        if (msg.sender != CONTROLLER && msg.sender != MODERATOR && msg.sender != r.author) revert CRL_Unauthorized();
        RecipeStatus oldStatus = r.status;
        r.status = newStatus;
        r.modifiedTs = uint64(block.timestamp);
        emit StatusChanged(recipeId, oldStatus, newStatus, uint64(block.timestamp));
    }

    function openPoll(uint256 recipeId) external onlyModerator whenRunning {
        RecipeData storage r = recipes[recipeId];
        if (r.recipeId == 0) revert CRL_NotFound();
        if (r.status != RecipeStatus.Live && r.status != RecipeStatus.Draft) revert CRL_InvalidState();
        PollData storage p = polls[recipeId];
        if (!p.closed && p.openedTs != 0) revert CRL_Already();
        r.status = RecipeStatus.InPoll;
        r.modifiedTs = uint64(block.timestamp);
        polls[recipeId] = PollData({ openedTs: uint64(block.timestamp), approveVotes: 0, rejectVotes: 0, closed: false, approved: false });
        emit PollStarted(recipeId, uint64(block.timestamp));
    }

    function castVote(uint256 recipeId, bool approve) external whenRunning {
        RecipeData storage r = recipes[recipeId];
        if (r.recipeId == 0) revert CRL_NotFound();
        if (r.status != RecipeStatus.InPoll) revert CRL_InvalidState();
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) revert CRL_InvalidState();
        if (hasVoted[recipeId][msg.sender]) revert CRL_Already();
        hasVoted[recipeId][msg.sender] = true;
        if (approve) p.approveVotes += 1; else p.rejectVotes += 1;
        emit VoteCast(recipeId, msg.sender, approve, uint64(block.timestamp));
    }

    function closePoll(uint256 recipeId) external whenRunning {
        RecipeData storage r = recipes[recipeId];
        if (r.recipeId == 0) revert CRL_NotFound();
        if (r.status != RecipeStatus.InPoll) revert CRL_InvalidState();
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) revert CRL_InvalidState();
        if (block.timestamp < uint256(p.openedTs) + POLL_DURATION) revert CRL_InvalidState();
        p.closed = true;
        uint256 total = uint256(p.approveVotes) + uint256(p.rejectVotes);
        uint256 quorumBp = total == 0 ? 0 : (uint256(p.approveVotes) * BPS) / total;
        p.approved = quorumBp >= QUORUM_BP;
        r.status = p.approved ? RecipeStatus.Live : RecipeStatus.Retired;
        r.modifiedTs = uint64(block.timestamp);
        emit PollClosed(recipeId, p.approved, p.approveVotes, p.rejectVotes, uint64(block.timestamp));
    }

    function setStopped(bool stop) external onlyController {
        stopped = stop;
        emit StoppedSet(stopped, uint64(block.timestamp));
    }

    function getRecipe(uint256 recipeId) external view returns (RecipeData memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId];
    }

    function getPackHashes(uint256 recipeId) external view returns (bytes32[] memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return _packHashes[recipeId];
    }

    function getCollaborators(uint256 recipeId) external view returns (address[] memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return _collabList[recipeId];
    }

    function getAuthoredIds(address author) external view returns (uint256[] memory) {
        return _authoredIds[author];
    }

    function getPoll(uint256 recipeId) external view returns (PollData memory) {
        return polls[recipeId];
    }

    function estimateQuorumBp(uint32 approveVotes, uint32 rejectVotes) external pure returns (uint256) {
        uint256 total = uint256(approveVotes) + uint256(rejectVotes);
        if (total == 0) return 0;
        return (uint256(approveVotes) * BPS) / total;
    }

    function getRoles() external view returns (address, address, address, address) {
        return (CONTROLLER, MODERATOR, PIPELINE, FEE_RECIPIENT);
    }

    function getConfig() external pure returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, bytes32) {
        return (MAX_PACK_ENTRIES, MAX_DURATION_SEC, MAX_TITLE_LEN, MAX_RECIPES_CAP, MAX_COLLABORATORS, POLL_DURATION, QUORUM_BP, APP_NAMESPACE);
    }

    uint256 public constant MAX_BULK = 80;
    uint256 public constant MIN_CHUCKLE = 0;
    uint256 public constant MAX_CHUCKLE = 9999;
    bytes32 public constant BUILD_TAG = keccak256("ClipRecipeLedger.0x_GenV_99.build.1");

    struct RecipeSummary {
        uint256 recipeId;
        address author;
        string title;
        uint32 durationSec;
        uint32 chuckleLevel;
        RecipeStatus status;
        uint64 createdTs;
    }

    function getRecipeSummary(uint256 recipeId) external view returns (RecipeSummary memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        RecipeData storage r = recipes[recipeId];
        return RecipeSummary({
            recipeId: r.recipeId,
            author: r.author,
            title: r.title,
            durationSec: r.durationSec,
            chuckleLevel: r.chuckleLevel,
            status: r.status,
            createdTs: r.createdTs
        });
    }

    function getSummaries(uint256 fromId, uint256 count) external view returns (RecipeSummary[] memory result) {
        if (count == 0 || count > MAX_BULK) revert CRL_InvalidInput();
        uint256 end = fromId + count;
        if (end > recipeCounter + 1) end = recipeCounter + 1;
        uint256 len = end > fromId ? end - fromId : 0;
        result = new RecipeSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = fromId + i;
            RecipeData storage r = recipes[id];
            if (r.recipeId == 0) continue;
            result[i] = RecipeSummary({
                recipeId: r.recipeId,
                author: r.author,
                title: r.title,
                durationSec: r.durationSec,
                chuckleLevel: r.chuckleLevel,
                status: r.status,
                createdTs: r.createdTs
            });
        }
    }

    function getRecipesInStatus(RecipeStatus status, uint256 fromId, uint256 count) external view returns (uint256[] memory ids) {
        if (count > MAX_BULK) count = MAX_BULK;
        uint256[] memory temp = new uint256[](count);
        uint256 found = 0;
        uint256 start = fromId == 0 ? 1 : fromId;
        for (uint256 id = start; id <= recipeCounter && found < count; id++) {
            if (recipes[id].status == status) {
                temp[found] = id;
                found++;
            }
        }
        ids = new uint256[](found);
        for (uint256 i = 0; i < found; i++) ids[i] = temp[i];
    }

    function countByStatus(RecipeStatus status) external view returns (uint256) {
        uint256 n = 0;
        for (uint256 id = 1; id <= recipeCounter; id++) {
            if (recipes[id].status == status) n++;
        }
        return n;
    }

    function getAuthorRecipeCount(address author) external view returns (uint256) {
        return _authoredIds[author].length;
    }

    function getAuthorRecipesPaginated(address author, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage arr = _authoredIds[author];
        if (offset >= arr.length) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > arr.length) end = arr.length;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = arr[offset + i];
    }

    function getRecipeTitle(uint256 recipeId) external view returns (string memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].title;
    }

    function getRecipeAuthor(uint256 recipeId) external view returns (address) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].author;
    }

    function getRecipePackHash(uint256 recipeId) external view returns (bytes32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].packHash;
    }

    function getRecipeTimelineHash(uint256 recipeId) external view returns (bytes32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].timelineHash;
    }

    function getRecipeDuration(uint256 recipeId) external view returns (uint32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].durationSec;
    }

    function getRecipeChuckleLevel(uint256 recipeId) external view returns (uint32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].chuckleLevel;
    }

    function getRecipeMixSeed(uint256 recipeId) external view returns (uint32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].mixSeed;
    }

    function getRecipeCreatedTs(uint256 recipeId) external view returns (uint64) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].createdTs;
    }

    function getRecipeModifiedTs(uint256 recipeId) external view returns (uint64) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].modifiedTs;
    }

    function getRecipeStatus(uint256 recipeId) external view returns (RecipeStatus) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].status;
    }

    function getPackEntryAt(uint256 recipeId, uint256 index) external view returns (bytes32) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        bytes32[] storage arr = _packHashes[recipeId];
        if (index >= arr.length) revert CRL_InvalidInput();
        return arr[index];
    }

    function getPackLength(uint256 recipeId) external view returns (uint256) {
        return _packHashes[recipeId].length;
    }

    function getCollabAt(uint256 recipeId, uint256 index) external view returns (address) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        address[] storage arr = _collabList[recipeId];
        if (index >= arr.length) revert CRL_InvalidInput();
        return arr[index];
    }

    function getCollabLength(uint256 recipeId) external view returns (uint256) {
        return _collabList[recipeId].length;
    }

    function getPollOpenedTs(uint256 recipeId) external view returns (uint64) {
        return polls[recipeId].openedTs;
    }

    function getPollApproveVotes(uint256 recipeId) external view returns (uint32) {
        return polls[recipeId].approveVotes;
    }

    function getPollRejectVotes(uint256 recipeId) external view returns (uint32) {
        return polls[recipeId].rejectVotes;
    }

    function getPollClosed(uint256 recipeId) external view returns (bool) {
        return polls[recipeId].closed;
    }

    function getPollApproved(uint256 recipeId) external view returns (bool) {
        return polls[recipeId].approved;
    }

    function didVote(uint256 recipeId, address account) external view returns (bool) {
        return hasVoted[recipeId][account];
    }

    function recipeExists(uint256 recipeId) external view returns (bool) {
        return recipes[recipeId].recipeId != 0;
    }

    function getController() external view returns (address) { return CONTROLLER; }
    function getModerator() external view returns (address) { return MODERATOR; }
    function getPipeline() external view returns (address) { return PIPELINE; }
    function getFeeRecipient() external view returns (address) { return FEE_RECIPIENT; }
    function getLaunchTs() external view returns (uint256) { return LAUNCH_TS; }
    function isStopped() external view returns (bool) { return stopped; }
    function getRecipeCounter() external view returns (uint256) { return recipeCounter; }

    function getRecipeDataFull(uint256 recipeId) external view returns (
        uint256 id,
        address authorAddr,
        string memory titleStr,
        bytes32 packH,
        bytes32 timelineH,
        uint32 durSec,
        uint32 chuckle,
        uint32 mixS,
        uint64 createdT,
        uint64 modifiedT,
        RecipeStatus st
    ) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        RecipeData storage r = recipes[recipeId];
        return (
            r.recipeId,
            r.author,
            r.title,
            r.packHash,
            r.timelineHash,
            r.durationSec,
            r.chuckleLevel,
            r.mixSeed,
            r.createdTs,
            r.modifiedTs,
            r.status
        );
    }

    function getStatusName(RecipeStatus status) external pure returns (string memory) {
        if (status == RecipeStatus.Empty) return "Empty";
        if (status == RecipeStatus.Draft) return "Draft";
        if (status == RecipeStatus.Live) return "Live";
        if (status == RecipeStatus.InPoll) return "InPoll";
        if (status == RecipeStatus.Retired) return "Retired";
        return "Unknown";
    }

    function getStatusForRecipe(uint256 recipeId) external view returns (RecipeStatus) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId].status;
    }

    function remainingRecipeSlots() external view returns (uint256) {
        if (recipeCounter >= MAX_RECIPES_CAP) return 0;
        return MAX_RECIPES_CAP - recipeCounter;
    }

    function maxRecipesCap() external pure returns (uint256) { return MAX_RECIPES_CAP; }
    function maxPackEntries() external pure returns (uint256) { return MAX_PACK_ENTRIES; }
    function maxDurationSec() external pure returns (uint256) { return MAX_DURATION_SEC; }
    function maxTitleLen() external pure returns (uint256) { return MAX_TITLE_LEN; }
    function maxCollaborators() external pure returns (uint256) { return MAX_COLLABORATORS; }
    function pollDuration() external pure returns (uint256) { return POLL_DURATION; }
    function quorumBp() external pure returns (uint256) { return QUORUM_BP; }
    function bps() external pure returns (uint256) { return BPS; }
    function appNamespace() external pure returns (bytes32) { return APP_NAMESPACE; }
    function seedMagic() external pure returns (bytes32) { return SEED_MAGIC; }
    function buildTag() external pure returns (bytes32) { return BUILD_TAG; }
    function maxBulk() external pure returns (uint256) { return MAX_BULK; }

    function getRecipeIdsInRange(uint256 low, uint256 high) external view returns (uint256[] memory ids) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint256[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = low + i;
    }

    function getTitlesForRange(uint256 low, uint256 high) external view returns (string[] memory titles) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new string[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        titles = new string[](len);
        for (uint256 i = 0; i < len; i++) titles[i] = recipes[low + i].title;
    }

    function getAuthorsForRange(uint256 low, uint256 high) external view returns (address[] memory authors) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new address[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        authors = new address[](len);
        for (uint256 i = 0; i < len; i++) authors[i] = recipes[low + i].author;
    }

    function getPackHashesForRange(uint256 low, uint256 high) external view returns (bytes32[] memory hashes) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new bytes32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) hashes[i] = recipes[low + i].packHash;
    }

    function getTimelineHashesForRange(uint256 low, uint256 high) external view returns (bytes32[] memory hashes) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new bytes32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) hashes[i] = recipes[low + i].timelineHash;
    }

    function getDurationsForRange(uint256 low, uint256 high) external view returns (uint32[] memory durs) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        durs = new uint32[](len);
        for (uint256 i = 0; i < len; i++) durs[i] = recipes[low + i].durationSec;
    }

    function getChuckleLevelsForRange(uint256 low, uint256 high) external view returns (uint32[] memory levels) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint32[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        levels = new uint32[](len);
        for (uint256 i = 0; i < len; i++) levels[i] = recipes[low + i].chuckleLevel;
    }

    function getStatusesForRange(uint256 low, uint256 high) external view returns (uint8[] memory statuses) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint8[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        statuses = new uint8[](len);
        for (uint256 i = 0; i < len; i++) statuses[i] = uint8(recipes[low + i].status);
    }

    function getCreatedTsForRange(uint256 low, uint256 high) external view returns (uint64[] memory ts) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint64[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        ts = new uint64[](len);
        for (uint256 i = 0; i < len; i++) ts[i] = recipes[low + i].createdTs;
    }

    function getModifiedTsForRange(uint256 low, uint256 high) external view returns (uint64[] memory ts) {
        if (low == 0) low = 1;
        if (high > recipeCounter) high = recipeCounter;
        if (low > high) return new uint64[](0);
        uint256 len = high - low + 1;
        if (len > MAX_BULK) len = MAX_BULK;
        ts = new uint64[](len);
        for (uint256 i = 0; i < len; i++) ts[i] = recipes[low + i].modifiedTs;
    }

    function getSummariesForIds(uint256[] calldata ids) external view returns (RecipeSummary[] memory result) {
        result = new RecipeSummary[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (recipes[id].recipeId == 0) continue;
            RecipeData storage r = recipes[id];
            result[i] = RecipeSummary({
                recipeId: r.recipeId,
                author: r.author,
                title: r.title,
                durationSec: r.durationSec,
                chuckleLevel: r.chuckleLevel,
                status: r.status,
                createdTs: r.createdTs
            });
        }
    }

    function isController(address account) external view returns (bool) { return account == CONTROLLER; }
    function isModerator(address account) external view returns (bool) { return account == MODERATOR; }
    function isPipeline(address account) external view returns (bool) { return account == PIPELINE; }
    function isFeeRecipient(address account) external view returns (bool) { return account == FEE_RECIPIENT; }

    function getRolesArray() external view returns (address[4] memory roles) {
        roles[0] = CONTROLLER;
        roles[1] = MODERATOR;
        roles[2] = PIPELINE;
        roles[3] = FEE_RECIPIENT;
    }

    function statusIsDraft(uint256 recipeId) external view returns (bool) { return recipes[recipeId].status == RecipeStatus.Draft; }
    function statusIsLive(uint256 recipeId) external view returns (bool) { return recipes[recipeId].status == RecipeStatus.Live; }
    function statusIsInPoll(uint256 recipeId) external view returns (bool) { return recipes[recipeId].status == RecipeStatus.InPoll; }
    function statusIsRetired(uint256 recipeId) external view returns (bool) { return recipes[recipeId].status == RecipeStatus.Retired; }
    function statusIsEmpty(uint256 recipeId) external view returns (bool) { return recipes[recipeId].status == RecipeStatus.Empty; }

    function packHashesForRecipes(uint256[] calldata ids) external view returns (bytes32[][] memory out) {
        out = new bytes32[][](ids.length);
        for (uint256 i = 0; i < ids.length; i++) out[i] = _packHashes[ids[i]];
    }

    function collabListsForRecipes(uint256[] calldata ids) external view returns (address[][] memory out) {
        out = new address[][](ids.length);
        for (uint256 i = 0; i < ids.length; i++) out[i] = _collabList[ids[i]];
    }

    function packLengthsForRecipes(uint256[] calldata ids) external view returns (uint256[] memory lens) {
        lens = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) lens[i] = _packHashes[ids[i]].length;
    }

    function collabLengthsForRecipes(uint256[] calldata ids) external view returns (uint256[] memory lens) {
        lens = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) lens[i] = _collabList[ids[i]].length;
    }

    function validateTitle(string calldata title) external pure returns (bool) {
        uint256 len = bytes(title).length;
        return len > 0 && len <= MAX_TITLE_LEN;
    }

    function validateDuration(uint32 durationSec) external pure returns (bool) {
        return durationSec > 0 && durationSec <= MAX_DURATION_SEC;
    }

    function validatePackSize(uint256 size) external pure returns (bool) {
        return size > 0 && size <= MAX_PACK_ENTRIES;
    }

    function validateCollabCount(uint256 count) external pure returns (bool) {
        return count <= MAX_COLLABORATORS;
    }

    function validateChuckleLevel(uint32 level) external pure returns (bool) {
        return level >= MIN_CHUCKLE && level <= MAX_CHUCKLE;
    }

    function validateRecipeId(uint256 recipeId) external view returns (bool) {
        return recipeId != 0 && recipeId <= recipeCounter && recipes[recipeId].recipeId != 0;
    }

    function getNextRecipeId() external view returns (uint256) {
        return recipeCounter + 1;
    }

    function wouldExceedCap(uint256 additional) external view returns (bool) {
        return recipeCounter + additional > MAX_RECIPES_CAP;
    }

    function configPack1() external pure returns (uint256 a, uint256 b, uint256 c, uint256 d) {
        return (MAX_PACK_ENTRIES, MAX_DURATION_SEC, MAX_TITLE_LEN, MAX_RECIPES_CAP);
    }

    function configPack2() external pure returns (uint256 a, uint256 b, uint256 c, uint256 d) {
        return (MAX_COLLABORATORS, POLL_DURATION, QUORUM_BP, MAX_BULK);
    }

    function protocolInfo() external pure returns (string memory name, bytes32 ns, bytes32 tag) {
        name = "ClipRecipeLedger";
        ns = APP_NAMESPACE;
        tag = BUILD_TAG;
    }

    function timeSinceLaunch() external view returns (uint256) {
        return block.timestamp - LAUNCH_TS;
    }

    function pollCanClose(uint256 recipeId) external view returns (bool) {
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) return false;
        return block.timestamp >= uint256(p.openedTs) + POLL_DURATION;
    }

    function pollBlocksRemaining(uint256 recipeId) external view returns (uint256) {
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) return 0;
        uint256 endTs = uint256(p.openedTs) + POLL_DURATION;
        if (block.timestamp >= endTs) return 0;
        return endTs - block.timestamp;
    }

    function aggregateDraftCountByAuthor(address author) external view returns (uint256 count) {
        uint256[] storage ids = _authoredIds[author];
        for (uint256 i = 0; i < ids.length; i++) {
            if (recipes[ids[i]].status == RecipeStatus.Draft) count++;
        }
    }

    function aggregateLiveCountByAuthor(address author) external view returns (uint256 count) {
        uint256[] storage ids = _authoredIds[author];
        for (uint256 i = 0; i < ids.length; i++) {
            if (recipes[ids[i]].status == RecipeStatus.Live) count++;
        }
    }

    function aggregateInPollCountByAuthor(address author) external view returns (uint256 count) {
        uint256[] storage ids = _authoredIds[author];
        for (uint256 i = 0; i < ids.length; i++) {
            if (recipes[ids[i]].status == RecipeStatus.InPoll) count++;
        }
    }

    function aggregateRetiredCountByAuthor(address author) external view returns (uint256 count) {
        uint256[] storage ids = _authoredIds[author];
        for (uint256 i = 0; i < ids.length; i++) {
            if (recipes[ids[i]].status == RecipeStatus.Retired) count++;
        }
    }

    function getRecipeDataStruct(uint256 recipeId) external view returns (RecipeData memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId];
    }

    function getPollDataStruct(uint256 recipeId) external view returns (PollData memory) {
        return polls[recipeId];
    }

    function minChuckle() external pure returns (uint256) { return MIN_CHUCKLE; }
    function maxChuckle() external pure returns (uint256) { return MAX_CHUCKLE; }

    struct BulkResult {
        RecipeSummary[] items;
        uint256 nextOffset;
        bool hasMore;
    }

    function getBulkSummaries(uint256 offset, uint256 limit) external view returns (BulkResult memory) {
        if (limit > MAX_BULK) limit = MAX_BULK;
        uint256 total = recipeCounter;
        if (offset >= total) {
            return BulkResult({ items: new RecipeSummary[](0), nextOffset: offset, hasMore: false });
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 len = end - offset;
        RecipeSummary[] memory arr = new RecipeSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = offset + i + 1;
            RecipeData storage r = recipes[id];
            arr[i] = RecipeSummary({
                recipeId: r.recipeId,
                author: r.author,
                title: r.title,
                durationSec: r.durationSec,
                chuckleLevel: r.chuckleLevel,
                status: r.status,
                createdTs: r.createdTs
            });
        }
        return BulkResult({ items: arr, nextOffset: end, hasMore: end < total });
    }

    function getPackHashesBatch(uint256 recipeId, uint256[] calldata indices) external view returns (bytes32[] memory out) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        bytes32[] storage arr = _packHashes[recipeId];
        out = new bytes32[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < arr.length) out[i] = arr[indices[i]];
        }
    }

    function getCollabBatch(uint256 recipeId, uint256[] calldata indices) external view returns (address[] memory out) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        address[] storage arr = _collabList[recipeId];
        out = new address[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] < arr.length) out[i] = arr[indices[i]];
        }
    }

    function titlesForRecipes(uint256[] calldata ids) external view returns (string[] memory titles) {
        titles = new string[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) titles[i] = recipes[ids[i]].title;
    }

    function authorsForRecipes(uint256[] calldata ids) external view returns (address[] memory authors) {
        authors = new address[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) authors[i] = recipes[ids[i]].author;
    }

    function packHashesForRecipesFlat(uint256[] calldata ids) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) hashes[i] = recipes[ids[i]].packHash;
    }

    function timelineHashesForRecipes(uint256[] calldata ids) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) hashes[i] = recipes[ids[i]].timelineHash;
    }

    function durationsForRecipes(uint256[] calldata ids) external view returns (uint32[] memory durs) {
        durs = new uint32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) durs[i] = recipes[ids[i]].durationSec;
    }

    function chuckleLevelsForRecipes(uint256[] calldata ids) external view returns (uint32[] memory levels) {
        levels = new uint32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) levels[i] = recipes[ids[i]].chuckleLevel;
    }

    function mixSeedsForRecipes(uint256[] calldata ids) external view returns (uint32[] memory seeds) {
        seeds = new uint32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) seeds[i] = recipes[ids[i]].mixSeed;
    }

    function createdTsForRecipes(uint256[] calldata ids) external view returns (uint64[] memory ts) {
        ts = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) ts[i] = recipes[ids[i]].createdTs;
    }

    function modifiedTsForRecipes(uint256[] calldata ids) external view returns (uint64[] memory ts) {
        ts = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) ts[i] = recipes[ids[i]].modifiedTs;
    }

    function statusesForRecipes(uint256[] calldata ids) external view returns (uint8[] memory statuses) {
        statuses = new uint8[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) statuses[i] = uint8(recipes[ids[i]].status);
    }

    function getAuthoredIdsAll(address author) external view returns (uint256[] memory) {
        return _authoredIds[author];
    }

    function getAuthoredSlice(address author, uint256 start, uint256 length) external view returns (uint256[] memory ids) {
        uint256[] storage arr = _authoredIds[author];
        if (start >= arr.length) return new uint256[](0);
        uint256 end = start + length;
        if (end > arr.length) end = arr.length;
        uint256 len = end - start;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = arr[start + i];
    }

    function roleCheck(address account) external view returns (bool ctrl, bool mod, bool pipe, bool fee) {
        ctrl = (account == CONTROLLER);
        mod = (account == MODERATOR);
        pipe = (account == PIPELINE);
        fee = (account == FEE_RECIPIENT);
    }

    function constantsPack1() external pure returns (uint256 a, uint256 b, uint256 c, uint256 d) {
        return (MAX_PACK_ENTRIES, MAX_DURATION_SEC, MAX_TITLE_LEN, MAX_RECIPES_CAP);
    }

    function constantsPack2() external pure returns (uint256 a, uint256 b, uint256 c, uint256 d) {
        return (MAX_COLLABORATORS, POLL_DURATION, QUORUM_BP, BPS);
    }

    function constantsPack3() external pure returns (bytes32 ns, bytes32 seed, bytes32 tag) {
        return (APP_NAMESPACE, SEED_MAGIC, BUILD_TAG);
    }

    function safeRecipeIdRange() external view returns (uint256 minId, uint256 maxId) {
        minId = 1;
        maxId = recipeCounter;
    }

    function recipeStatusIsDraft(uint256 recipeId) external view returns (bool) {
        return recipes[recipeId].status == RecipeStatus.Draft;
    }

    function recipeStatusIsLive(uint256 recipeId) external view returns (bool) {
        return recipes[recipeId].status == RecipeStatus.Live;
    }

    function recipeStatusIsInPoll(uint256 recipeId) external view returns (bool) {
        return recipes[recipeId].status == RecipeStatus.InPoll;
    }

    function recipeStatusIsRetired(uint256 recipeId) external view returns (bool) {
        return recipes[recipeId].status == RecipeStatus.Retired;
    }

    function pollIsOpen(uint256 recipeId) external view returns (bool) {
        PollData storage p = polls[recipeId];
        return p.openedTs != 0 && !p.closed;
    }

    function pollIsClosed(uint256 recipeId) external view returns (bool) {
        return polls[recipeId].closed;
    }

    function pollIsApproved(uint256 recipeId) external view returns (bool) {
        return polls[recipeId].approved;
    }

    function totalVotesForPoll(uint256 recipeId) external view returns (uint256) {
        PollData storage p = polls[recipeId];
        return uint256(p.approveVotes) + uint256(p.rejectVotes);
    }

    function quorumReached(uint256 recipeId) external view returns (bool) {
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) return false;
        uint256 total = uint256(p.approveVotes) + uint256(p.rejectVotes);
        if (total == 0) return false;
        uint256 bp = (uint256(p.approveVotes) * BPS) / total;
        return bp >= QUORUM_BP;
    }

    function estimateQuorumFor(uint32 approveV, uint32 rejectV) external pure returns (uint256 bp) {
        uint256 total = uint256(approveV) + uint256(rejectV);
        if (total == 0) return 0;
        return (uint256(approveV) * BPS) / total;
    }

    function isCollaborator(uint256 recipeId, address account) external view returns (bool) {
        address[] storage arr = _collabList[recipeId];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == account) return true;
        }
        return false;
    }

    function collaboratorCount(uint256 recipeId) external view returns (uint256) {
        return _collabList[recipeId].length;
    }

    function packEntryCount(uint256 recipeId) external view returns (uint256) {
        return _packHashes[recipeId].length;
    }

    function recipeCount() external view returns (uint256) {
        return recipeCounter;
    }

    function launchTimestamp() external view returns (uint256) {
        return LAUNCH_TS;
    }

    function mutexValue() external pure returns (uint256) {
        return MUTEX;
    }

    function namespace() external pure returns (bytes32) {
        return APP_NAMESPACE;
    }

    function seedMagicConstant() external pure returns (bytes32) {
        return SEED_MAGIC;
    }

    function buildTagConstant() external pure returns (bytes32) {
        return BUILD_TAG;
    }

    function maxBulkQuery() external pure returns (uint256) {
        return MAX_BULK;
    }

    function getRecipeFull(uint256 recipeId) external view returns (RecipeData memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId];
    }

    function getPackHashesFull(uint256 recipeId) external view returns (bytes32[] memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return _packHashes[recipeId];
    }

    function getCollaboratorsFull(uint256 recipeId) external view returns (address[] memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return _collabList[recipeId];
    }

    function getPollFull(uint256 recipeId) external view returns (PollData memory) {
        return polls[recipeId];
    }

    function recipeById(uint256 recipeId) external view returns (RecipeData memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        return recipes[recipeId];
    }

    function pollById(uint256 recipeId) external view returns (PollData memory) {
        return polls[recipeId];
    }

    function summaryById(uint256 recipeId) external view returns (RecipeSummary memory) {
        if (recipes[recipeId].recipeId == 0) revert CRL_NotFound();
        RecipeData storage r = recipes[recipeId];
        return RecipeSummary({
            recipeId: r.recipeId,
            author: r.author,
            title: r.title,
            durationSec: r.durationSec,
            chuckleLevel: r.chuckleLevel,
            status: r.status,
            createdTs: r.createdTs
        });
    }

    function allConfig() external pure returns (
        uint256 packEntries,
        uint256 durationSec,
        uint256 titleLen,
        uint256 recipesCap,
        uint256 collaborators,
        uint256 pollDur,
        uint256 quorumBpVal,
        uint256 bpsVal
    ) {
        return (
            MAX_PACK_ENTRIES,
            MAX_DURATION_SEC,
            MAX_TITLE_LEN,
            MAX_RECIPES_CAP,
            MAX_COLLABORATORS,
            POLL_DURATION,
            QUORUM_BP,
            BPS
        );
    }

    function allRolesView() external view returns (
        address controllerAddr,
        address moderatorAddr,
        address pipelineAddr,
        address feeRecipientAddr
    ) {
        return (CONTROLLER, MODERATOR, PIPELINE, FEE_RECIPIENT);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }

    function protocolName() external pure returns (string memory) {
        return "ClipRecipeLedger";
    }

    function protocolVersion() external pure returns (uint256) {
        return 1;
    }

    function protocolNamespace() external pure returns (bytes32) {
        return APP_NAMESPACE;
    }

    function protocolBuildTag() external pure returns (bytes32) {
        return BUILD_TAG;
    }

    function getNextId() external view returns (uint256) {
        return recipeCounter + 1;
    }

    function canCreateRecipe() external view returns (bool) {
        return !stopped && recipeCounter < MAX_RECIPES_CAP;
    }

    function canVote(uint256 recipeId, address account) external view returns (bool) {
        if (recipes[recipeId].status != RecipeStatus.InPoll) return false;
        if (polls[recipeId].closed || polls[recipeId].openedTs == 0) return false;
        return !hasVoted[recipeId][account];
    }

    function canClosePoll(uint256 recipeId) external view returns (bool) {
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) return false;
        return block.timestamp >= uint256(p.openedTs) + POLL_DURATION;
    }

    function timeUntilPollClosable(uint256 recipeId) external view returns (uint256) {
        PollData storage p = polls[recipeId];
        if (p.closed || p.openedTs == 0) return 0;
        uint256 endTs = uint256(p.openedTs) + POLL_DURATION;
        if (block.timestamp >= endTs) return 0;
        return endTs - block.timestamp;
    }

    function approveVotesFor(uint256 recipeId) external view returns (uint32) {
        return polls[recipeId].approveVotes;
    }

    function rejectVotesFor(uint256 recipeId) external view returns (uint32) {
        return polls[recipeId].rejectVotes;
    }

    function pollOpenedAt(uint256 recipeId) external view returns (uint64) {
        return polls[recipeId].openedTs;
    }

    function recipeAuthorOf(uint256 recipeId) external view returns (address) {
        return recipes[recipeId].author;
    }

    function recipeTitleOf(uint256 recipeId) external view returns (string memory) {
        return recipes[recipeId].title;
    }

    function recipePackHashOf(uint256 recipeId) external view returns (bytes32) {
        return recipes[recipeId].packHash;
    }

    function recipeTimelineHashOf(uint256 recipeId) external view returns (bytes32) {
        return recipes[recipeId].timelineHash;
    }

    function recipeDurationOf(uint256 recipeId) external view returns (uint32) {
        return recipes[recipeId].durationSec;
    }

    function recipeChuckleOf(uint256 recipeId) external view returns (uint32) {
        return recipes[recipeId].chuckleLevel;
    }

    function recipeMixSeedOf(uint256 recipeId) external view returns (uint32) {
        return recipes[recipeId].mixSeed;
    }

    function recipeCreatedAt(uint256 recipeId) external view returns (uint64) {
        return recipes[recipeId].createdTs;
    }

    function recipeModifiedAt(uint256 recipeId) external view returns (uint64) {
        return recipes[recipeId].modifiedTs;
    }

    function recipeStatusOf(uint256 recipeId) external view returns (RecipeStatus) {
        return recipes[recipeId].status;
    }

