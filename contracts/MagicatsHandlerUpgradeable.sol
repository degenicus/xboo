// SPDX-License-Identifier: BSL1.1

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IMagicats.sol";
import "./interfaces/IAceLab.sol";
import "./interfaces/IBooMirrorWorld.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/IVault.sol";

contract MagicatsHandlerUpgradeable is
    AccessControlEnumerableUpgradeable,
    ERC721EnumerableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant KEEPER = keccak256("KEEPER");
    bytes32 public constant STRATEGIST = keccak256("STRATEGIST");
    bytes32 public constant STRATEGY = keccak256("STRATEGY");
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32[] private cascadingAccess;

    uint256 public upgradeProposalTime;
    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant UPGRADE_TIMELOCK = 48 hours; // minimum 48 hours for RF

    address public constant ACELAB = 0x399D73bB7c83a011cD85DF2a3CdF997ED3B3439f;
    address public constant MAGICATS = 0x2aB5C606a5AA2352f8072B9e2E8A213033e2c4c9;
    IERC20Upgradeable public constant BOO = IERC20Upgradeable(0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE); // BOO

    address public vault;

    /***
     * @dev Struct used for internal accounting of deposited MAGICATS
     * {magicatId} - the Id of the deposited magicat
     * {manapoints} - the associated manapoints of the magicat, used for determining share of rewards
     * {lastHarvestClaimed} - position in array of last claimed rewards, initalized as the length of the array
     */
    struct Magicat {
        uint256 magicatId;
        uint256 manapoints;
        uint256 lastHarvestClaimed;
    }
    /***
     * @dev Struct used for interal accounting of harvested rewards, denominated in boo vaultshares
     * {amount} - the total amount of the harvest in vaultshares
     * {totalManaPoints} - the total amount of manapoints from all deposited magicats
     * {timestamp} - block timestamp of harvest, used for calculating apr
     */
    struct Harvest {
        uint256 amount;
        uint256 totalManaPoints;
        uint256 timestamp;
    }

    // total manapoints of all deposited magicats
    uint256 public totalMp;

    // array of harvests, written each time harvest is called
    Harvest[] public harvests;

    /***
     * {idToMagicat} - magicatId to Magicat Struct
     * {magicatIdToStakedPid} - mapping for keeping track of where each magicat is deposited in the ACELAB contract
     */
    mapping(uint256 => Magicat) public idToMagicat;
    mapping(uint256 => uint256) public magicatIdToStakedPid;

    // address of the strategy the magicatsHandler hooks into
    address public strategy;

    /**
     * @dev Variables for off-chain bot
     * {lastAllocationTimestamp} - The block.timestamp of the most recent call to updateStakedMagicats
     * allowing the bot not to make unecessary re-allocations
     */
    uint256 public lastAllocationTimestamp;

    //      catID -> savedPendingRewards 
    mapping(uint256 => uint256) public savedRewards;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        address _strategy,
        address _vault,
        address[] memory _strategists,
        address _multisig
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControlEnumerable_init();
        __ERC721_init("Reaper Magicats", "rfMagicats");

        strategy = _strategy;
        _grantRole(STRATEGY, strategy);
        _approveMagicatsFor(strategy);
        vault = _vault;

        _grantRole(ADMIN, msg.sender);
        _grantRole(ADMIN, _multisig);

        for (uint256 i = 0; i < _strategists.length; i = _uncheckedInc(i)) {
            _grantRole(STRATEGIST, _strategists[i]);
        }

        cascadingAccess = [ADMIN, STRATEGY, STRATEGIST, KEEPER];
    }

    /***
     * @notice deposit function for Magicat NFTs
     * @param magicatsIds - array of NFT ids to deposit
     * @dev creates a mirrored NFT of the deposit that allows for claiming rewards
     * as well as reclaiming of deposited NFT. Sends NFTs directly to strategy
     */
    function deposit(uint256[] memory magicatsIds) external {
        Magicat memory deposited;
        for (uint256 i; i < magicatsIds.length; i = _uncheckedInc(i)) {
            deposited.magicatId = magicatsIds[i];
            deposited.manapoints = IAceLab(ACELAB).rarityOf(magicatsIds[i]);
            deposited.lastHarvestClaimed = harvests.length;

            totalMp += deposited.manapoints;
            idToMagicat[magicatsIds[i]] = deposited;

            IERC721Upgradeable(MAGICATS).safeTransferFrom(msg.sender, strategy, magicatsIds[i]);

            _safeMint(msg.sender, magicatsIds[i]);
        }
        _updateStakedMagicats(IStrategy(strategy).currentPoolId(), magicatsIds, new uint256[](0));
    }

    /***
     * @notice Withdraw function for Magicat NFTs
     * @param magicatsIds - array of NFTs to withdraw
     * @dev rewards are forcefully claimed for all withdrawn nfts because they would be lost in limbo otherwise
     * this also burns the underlying nft.
     *
     * this function accounts for a possible case where this particular version of the magicatsHandler is retired from use,
     * in this case, the NFTs are not in the strategy anymore but back in this contract for safe retrieval by their rightful owners
     */
    function withdraw(uint256[] memory magicatsIds) external {
        claimRewards(magicatsIds);
        for (uint256 i; i < magicatsIds.length; i = _uncheckedInc(i)) {
            require(_isApprovedOrOwner(msg.sender, magicatsIds[i]), "!approved");
            totalMp -= idToMagicat[magicatsIds[i]].manapoints;
            _burn(magicatsIds[i]);

            uint256 stakedPoolId = magicatIdToStakedPid[magicatsIds[i]];
            delete idToMagicat[magicatsIds[i]];
            delete magicatIdToStakedPid[magicatsIds[i]];

            address currentOwner = IERC721Upgradeable(MAGICATS).ownerOf(magicatsIds[i]);

            if (currentOwner == ACELAB) {
                uint256[] memory unstake = new uint256[](1);
                unstake[0] = magicatsIds[i];
                _updateStakedMagicats(stakedPoolId, new uint256[](0), unstake);
                currentOwner = strategy;
            }

            IERC721Upgradeable(MAGICATS).transferFrom(currentOwner, msg.sender, magicatsIds[i]);
        }
    }

    /***
     * @dev internal function for interacting with the strategy-held magicats accross all poolIds
            magicatIDToStakedPid is only checked when this contract knows the magicat is staked in the acelab contract,
            therefore we do not need to update the data being stale on unstaking
     * @param poolID, the acelab poolID to operate on
     * @param IDsToStake the magicatIds to Stake
     * @param IDsToUnstake the magicatIds to unstake
     */
    function _updateStakedMagicats(
        uint256 poolID,
        uint256[] memory IDsToStake,
        uint256[] memory IDsToUnstake
    ) internal {
        IStrategy(strategy).updateMagicats(poolID, IDsToStake, IDsToUnstake);
        for (uint256 i = 0; i < IDsToStake.length; i = _uncheckedInc(i)) {
            magicatIdToStakedPid[IDsToStake[i]] = poolID;
        }
    }

    /***
     * @notice external function to update the staked magicats
     * @param poolID, the acelab poolID to operate on
     * @param IDsToStake the magicatIds to Stake
     * @param IDsToUnstake the magicatIds to unstake
     */
    function updateStakedMagicats(
        uint256 poolID,
        uint256[] memory IDsToStake,
        uint256[] memory IDsToUnstake,
        bool allocationCompleted
    ) external {
        _atLeastRole(KEEPER);
        _updateStakedMagicats(poolID, IDsToStake, IDsToUnstake);

        if (allocationCompleted) {
            lastAllocationTimestamp = block.timestamp;
        }
    }

    /***
     * @dev function for approving all MagicatNFTs for a specific address,
     * required for operability between strategy and handler
     */
    function _approveMagicatsFor(address operator) internal {
        IERC721Upgradeable(MAGICATS).setApprovalForAll(operator, true);
    }

    /***
     * @notice function for harvesting and redepositing boo into vault
     * writes to harvest log and allows for reward claims
     */
    function processRewards() external {
        Harvest memory latestHarvest;
        uint256 beforeAmount = IERC20Upgradeable(vault).balanceOf(address(this));
        _redepositGains();
        latestHarvest.amount = IERC20Upgradeable(vault).balanceOf(address(this)) - beforeAmount;
        latestHarvest.totalManaPoints = totalMp;
        latestHarvest.timestamp = block.timestamp;
        harvests.push(latestHarvest);
    }

    /***
     * @dev helper function calculating the unclaimed rewards of a single deposited ID
     * used by both the front end helper getMagicatsRewards, but also in the process of claiming
     * for a single ID
     */
    function getMagicatReward(uint256 id) public view returns (uint256) {
        uint256 totalHarvests = harvests.length;
        Magicat memory cat = idToMagicat[id];
        uint256 magicatShare;
        uint256 unclaimedReward;
        for (uint256 i = cat.lastHarvestClaimed; i < totalHarvests; i = _uncheckedInc(i)) {
            magicatShare = (harvests[i].amount * cat.manapoints) / harvests[i].totalManaPoints;
            unclaimedReward += magicatShare;
        }

        return unclaimedReward + savedRewards[id];
    }

    /***
     * @dev front end helper function for calculating the unclaimed rewards of an array of magicatIDs
     */
    function getMagicatRewards(uint256[] memory ids) public view returns (uint256) {
        uint256 unclaimedRewards;
        for (uint256 i = 0; i < ids.length; i = _uncheckedInc(i)) {
            unclaimedRewards += getMagicatReward(ids[i]);
        }
        return unclaimedRewards;
    }

    /***
     * @dev internal function for simple reward claiming
     * also updated the lastHarvestClaimed to align with Checks-Effects-Interaction pattern
     */
    function _claimRewards(uint256 _id) internal {
        uint256 owed = getMagicatReward(_id);
        delete savedRewards[_id];
        idToMagicat[_id].lastHarvestClaimed = harvests.length;
        IERC20(vault).transfer(msg.sender, owed);
    }

    /***
     * @notice function for claiming rewards of an array of IDs
     * @param ids - array of NFT ids to claim rewards for
     * @dev after claiming
     */
    function claimRewards(uint256[] memory ids) public {
        for (uint256 i = 0; i < ids.length; i = _uncheckedInc(i)) {
            require(_isApprovedOrOwner(msg.sender, ids[i]), "!approved");
            _claimRewards(ids[i]);
        }
    }

    /***
     * @dev internal function to deposit gained boo from strategy harvest back into the underlying vault
     */
    function _redepositGains() internal {
        uint256 booBal = BOO.balanceOf(address(this));
        BOO.approve(vault, booBal);
        IVault(vault).deposit(booBal);
    }

    /***
     * @notice view function/front-end helper for getting an array of magicat NFTs owned by user {owner}
     * @param owner - the address to query the Magicat balance of
     */
    function getDepositableMagicats(address owner) public view returns (uint256[] memory) {
        uint256 balance = IMagicat(MAGICATS).balanceOf(owner);
        uint256[] memory ids = new uint256[](balance);
        for (uint256 i = 0; i < balance; i = _uncheckedInc(i)) {
            ids[i] = IMagicat(MAGICATS).tokenOfOwnerByIndex(owner, i);
        }

        return ids;
    }

    /***
     * @notice view function for getting an array of deposited NFTs for an address:{owner}
     * @param owner - the address to query the internal NFT balance of
     */
    function getDepositedMagicats(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory ids = new uint256[](balance);
        for (uint256 i = 0; i < balance; i = _uncheckedInc(i)) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }

        return ids;
    }

    /***
     * @notice external function for iterating through all pools and unstaking all magicats
     * can be called by keeper for hard reset of staked NFTs for large repositioning as
     * management of nfts can be quite difficult to when doing large amounts of unstake-restaking
     */
    function massUnstakeMagicats() public {
        _atLeastRole(KEEPER);
        for (uint256 i = 0; i < IAceLab(ACELAB).poolLength(); i = _uncheckedInc(i)) {
            uint256[] memory stakedIds = IAceLab(ACELAB).getStakedMagicats(i, strategy);
            if (stakedIds.length != 0) {
                uint256[] memory empty;
                _updateStakedMagicats(i, empty, stakedIds);
            }
        }
    }

    function withdrawAllMagicatsFromStrategy() external {
        _atLeastRole(ADMIN);
        massUnstakeMagicats();
        uint256 stratBalance = IMagicat(MAGICATS).balanceOf(strategy);
        uint256[] memory stratIds = new uint256[](stratBalance);
        stratIds = getDepositableMagicats(strategy);
        for (uint256 i = 0; i < stratBalance; i = _uncheckedInc(i)) {
            IMagicat(MAGICATS).transferFrom(strategy, address(this), stratIds[i]);
        }
    }

    /**
     * @dev Internal function that checks cascading role privileges. Any higher privileged role
     * should be able to perform all the functions of any lower privileged role. This is
     * accomplished using the {cascadingAccess} array that lists all roles from most privileged
     * to least privileged.
     */
    function _atLeastRole(bytes32 role) internal view {
        uint256 numRoles = cascadingAccess.length;
        uint256 specifiedRoleIndex;
        for (uint256 i = 0; i < numRoles; i = _uncheckedInc(i)) {
            if (role == cascadingAccess[i]) {
                specifiedRoleIndex = i;
                break;
            } else if (i == numRoles - 1) {
                revert();
            }
        }

        for (uint256 i = 0; i <= specifiedRoleIndex; i = _uncheckedInc(i)) {
            if (hasRole(cascadingAccess[i], msg.sender)) {
                break;
            } else if (i == specifiedRoleIndex) {
                revert();
            }
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return (ERC721EnumerableUpgradeable.supportsInterface(interfaceId) ||
            AccessControlEnumerableUpgradeable.supportsInterface(interfaceId));
    }

    /// @notice For doing an unchecked increment of an index for gas optimization purposes
    /// @param i - The number to increment
    /// @return The incremented number
    function _uncheckedInc(uint256 i) internal pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    /**
     * @dev This function must be called prior to upgrading the implementation.
     *      It's required to wait UPGRADE_TIMELOCK seconds before executing the upgrade.
     *      Strategists and roles with higher privilege can initiate this cooldown.
     */
    function initiateUpgradeCooldown() external {
        _atLeastRole(STRATEGIST);
        upgradeProposalTime = block.timestamp;
    }

    /**
     * @dev This function is called:
     *      - in initialize()
     *      - as part of a successful upgrade
     *      - manually to clear the upgrade cooldown.
     * Admin and roles with higher privilege can clear this cooldown.
     */
    function clearUpgradeCooldown() public {
        _atLeastRole(ADMIN);
        upgradeProposalTime = block.timestamp + (ONE_YEAR * 100);
    }

    /**
     * @dev This function must be overriden simply for access control purposes.
     *      Only ADMIN can upgrade the implementation once the timelock
     *      has passed.
     */
    function _authorizeUpgrade(address) internal override {
        _atLeastRole(ADMIN);
        require(upgradeProposalTime + UPGRADE_TIMELOCK < block.timestamp);
        clearUpgradeCooldown();
    }

    function partialClaimRewards(uint256 magicatID, uint256 _harvests) public {
        uint256 totalHarvests = harvests.length;
        Magicat storage cat = idToMagicat[magicatID];
        uint256 magicatShare;
        uint256 unclaimedReward;
        uint256 lastHarvestClaimed = cat.lastHarvestClaimed;
        uint256 lastToClaim = lastHarvestClaimed + _harvests;
        if(lastToClaim > totalHarvests){
            lastToClaim = totalHarvests;
        }
        for(uint256 i = lastHarvestClaimed; i < lastToClaim; i = _uncheckedInc(i)){
            magicatShare = (harvests[i].amount * cat.manapoints) / harvests[i].totalManaPoints;
            unclaimedReward += magicatShare;
        }
        savedRewards[magicatID] += unclaimedReward;
        cat.lastHarvestClaimed = lastToClaim;
    }
}
