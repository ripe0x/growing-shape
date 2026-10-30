// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of the deployed Shapes contract (mainnet 0x6fe9193276bf7abcbee44ab7afd717d637d6faf0)
///         this protocol calls. Signatures follow the verified public source (github.com/ripe0x/shapes).
interface IShapes {
    function mintBatch(uint256 amountWei, uint256 quantity) external payable returns (uint256 firstTokenId);
    function compose(uint256 survivorId, uint256[] calldata burnIds) external returns (uint256);
    function mintFee() external view returns (uint256);
    function backingOf(uint256 tokenId) external view returns (uint256);
    function seedOf(uint256 tokenId) external view returns (bytes32);
    function composeDepth(uint256 survivorId) external view returns (uint256);
    function isSupportedDenomination(uint256 amountWei) external pure returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function totalMinted() external view returns (uint256);
}
