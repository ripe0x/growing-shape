// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of the deployed Draw Packs contract (mainnet 0xf21514b090da7df4390803497d6ae673801e5ca7)
///         this protocol calls. Source: github.com/ripe0x/shape-packs, branch draw-packs.
interface IShapePacks {
    /// @dev `mintCounts[d]` Shapes of denomination index `d` are minted into the new pack. Pays
    ///      backing plus one Shapes mint fee per Shape. Reverts below `MIN_PACK_VALUE` (0.03 ETH live).
    function createPack(uint256[] calldata shapeIds, uint32[] calldata mintCounts) external payable returns (uint256);
    function valueOf(uint256 packId) external view returns (uint256);
    function MIN_PACK_VALUE() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
}
