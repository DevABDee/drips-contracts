// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.17;

import {DripsHistory, DripsHub, DripsReceiver, SplitsReceiver, UserMetadata} from "./DripsHub.sol";
import {Upgradeable} from "./Upgradeable.sol";
import {Context, ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";
import {IERC20, SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {StorageSlot} from "openzeppelin-contracts/utils/StorageSlot.sol";
import {
    ERC721,
    ERC721Burnable
} from "openzeppelin-contracts/token/ERC721/extensions/ERC721Burnable.sol";

/// @notice A DripsHub driver implementing token-based user identification.
/// Anybody can mint a new token and create a new identity.
/// Only the current holder of the token can control its user ID.
/// The token ID and the user ID controlled by it are always equal.
contract NFTDriver is ERC721Burnable, ERC2771Context, Upgradeable {
    using SafeERC20 for IERC20;

    /// @notice The DripsHub address used by this driver.
    DripsHub public immutable dripsHub;
    /// @notice The driver ID which this driver uses when calling DripsHub.
    uint32 public immutable driverId;
    /// @notice The ERC-1967 storage slot holding a single `uint256` counter of minted tokens.
    bytes32 private immutable _mintedTokensSlot = erc1967Slot("eip1967.nftDriver.storage");

    /// @param _dripsHub The drips hub to use.
    /// @param forwarder The ERC-2771 forwarder to trust. May be the zero address.
    /// @param _driverId The driver ID to use when calling DripsHub.
    constructor(DripsHub _dripsHub, address forwarder, uint32 _driverId)
        ERC2771Context(forwarder)
        ERC721("DripsHub identity", "DHI")
    {
        dripsHub = _dripsHub;
        driverId = _driverId;
    }

    modifier onlyHolder(uint256 tokenId) {
        require(
            _isApprovedOrOwner(_msgSender(), tokenId),
            "ERC721: caller is not token owner or approved"
        );
        _;
    }

    /// @notice Get the ID of the next minted token.
    /// @return tokenId The token ID.
    function nextTokenId() public view returns (uint256 tokenId) {
        return (uint256(driverId) << 224) + StorageSlot.getUint256Slot(_mintedTokensSlot).value;
    }

    /// @notice Mints a new token controlling a new user ID and transfers it to an address.
    /// Emits user metadata for the new token.
    /// Usage of this method is discouraged, use `safeMint` whenever possible.
    /// @param to The address to transfer the minted token to.
    /// @param userMetadata The list of user metadata to emit for the minted token.
    /// The keys and the values are not standardized by the protocol, it's up to the user
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @return tokenId The minted token ID. It's equal to the user ID controlled by it.
    function mint(address to, UserMetadata[] calldata userMetadata)
        public
        returns (uint256 tokenId)
    {
        tokenId = _registerTokenId(userMetadata);
        _mint(to, tokenId);
    }

    /// @notice Mints a new token controlling a new user ID and safely transfers it to an address.
    /// Emits user metadata for the new token.
    /// @param to The address to transfer the minted token to.
    /// @param userMetadata The list of user metadata to emit for the minted token.
    /// The keys and the values are not standardized by the protocol, it's up to the user
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @return tokenId The minted token ID. It's equal to the user ID controlled by it.
    function safeMint(address to, UserMetadata[] calldata userMetadata)
        public
        returns (uint256 tokenId)
    {
        tokenId = _registerTokenId(userMetadata);
        _safeMint(to, tokenId);
    }

    /// @notice Registers the next token ID when minting.
    /// Emits the user metadata for the minted token.
    /// @param userMetadata The list of user metadata.
    /// @return tokenId The registered token ID.
    function _registerTokenId(UserMetadata[] calldata userMetadata)
        internal
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId();
        StorageSlot.getUint256Slot(_mintedTokensSlot).value++;
        if (userMetadata.length > 0) dripsHub.emitUserMetadata(tokenId, userMetadata);
    }

    /// @notice Collects the user's received already split funds
    /// and transfers them out of the drips hub contract.
    /// @param tokenId The ID of the token representing the collecting user ID.
    /// The caller must be the owner of the token or be approved to use it.
    /// The token ID is equal to the user ID controlled by it.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferrable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param transferTo The address to send collected funds to
    /// @return amt The collected amount
    function collect(uint256 tokenId, IERC20 erc20, address transferTo)
        public
        onlyHolder(tokenId)
        returns (uint128 amt)
    {
        amt = dripsHub.collect(tokenId, erc20);
        erc20.safeTransfer(transferTo, amt);
    }

    /// @notice Gives funds from the user to the receiver.
    /// The receiver can collect them immediately.
    /// Transfers the funds to be given from the message sender's wallet to the drips hub contract.
    /// @param tokenId The ID of the token representing the giving user ID.
    /// The caller must be the owner of the token or be approved to use it.
    /// The token ID is equal to the user ID controlled by it.
    /// @param receiver The receiver
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferrable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param amt The given amount
    function give(uint256 tokenId, uint256 receiver, IERC20 erc20, uint128 amt)
        public
        onlyHolder(tokenId)
    {
        _transferFromCaller(erc20, amt);
        dripsHub.give(tokenId, receiver, erc20, amt);
    }

    /// @notice Sets the user's drips configuration.
    /// Transfers funds between the message sender's wallet and the drips hub contract
    /// to fulfill the change of the drips balance.
    /// @param tokenId The ID of the token representing the configured user ID.
    /// The caller must be the owner of the token or be approved to use it.
    /// The token ID is equal to the user ID controlled by it.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferrable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The list of the drips receivers set in the last drips update
    /// of the sender.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The drips balance change to be applied.
    /// Positive to add funds to the drips balance, negative to remove them.
    /// @param newReceivers The list of the drips receivers of the sender to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @param transferTo The address to send funds to in case of decreasing balance
    /// @return realBalanceDelta The actually applied drips balance change.
    function setDrips(
        uint256 tokenId,
        IERC20 erc20,
        DripsReceiver[] calldata currReceivers,
        int128 balanceDelta,
        DripsReceiver[] calldata newReceivers,
        uint32 maxEndTip1,
        uint32 maxEndTip2,
        address transferTo
    ) public onlyHolder(tokenId) returns (int128 realBalanceDelta) {
        if (balanceDelta > 0) {
            _transferFromCaller(erc20, uint128(balanceDelta));
        }
        realBalanceDelta = dripsHub.setDrips(
            tokenId, erc20, currReceivers, balanceDelta, newReceivers, maxEndTip1, maxEndTip2
        );
        if (realBalanceDelta < 0) {
            erc20.safeTransfer(transferTo, uint128(-realBalanceDelta));
        }
    }

    /// @notice Sets the user's splits configuration.
    /// @param tokenId The ID of the token representing the configured user ID.
    /// The caller must be the owner of the token or be approved to use it.
    /// The token ID is equal to the user ID controlled by it.
    /// @param receivers The list of the user's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the user.
    function setSplits(uint256 tokenId, SplitsReceiver[] calldata receivers)
        public
        onlyHolder(tokenId)
    {
        dripsHub.setSplits(tokenId, receivers);
    }

    /// @notice Emits the user metadata for the given token.
    /// The keys and the values are not standardized by the protocol, it's up to the user
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param tokenId The ID of the token representing the emitting user ID.
    /// The caller must be the owner of the token or be approved to use it.
    /// The token ID is equal to the user ID controlled by it.
    /// @param userMetadata The list of user metadata.
    function emitUserMetadata(uint256 tokenId, UserMetadata[] calldata userMetadata)
        public
        onlyHolder(tokenId)
    {
        dripsHub.emitUserMetadata(tokenId, userMetadata);
    }

    function _transferFromCaller(IERC20 erc20, uint128 amt) internal {
        erc20.safeTransferFrom(_msgSender(), address(this), amt);
        address reserve = address(dripsHub.reserve());
        // Approval is done only on the first usage of the ERC-20 token in the reserve by the driver
        if (erc20.allowance(address(this), reserve) == 0) {
            erc20.safeApprove(reserve, type(uint256).max);
        }
    }

    // Workaround for https://github.com/ethereum/solidity/issues/12554
    function _msgSender() internal view override (Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    // Workaround for https://github.com/ethereum/solidity/issues/12554
    function _msgData() internal view override (Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }
}
