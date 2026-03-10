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
