// SPDX-License-Identifier: AGPL v3
pragma solidity ^0.8.24;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IVersionable } from "../interfaces/IVersionable.sol";
import { ITTUFeeCollector } from "@ethsign/tokentable-evm-contracts/contracts/interfaces/ITTUFeeCollector.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMDCreate2 {
    function feeTokens(address deployment) external view returns (address);
    function feeCollectors(address deployment) external view returns (address);
}

abstract contract BaseMerkleDistributor is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IVersionable
{
    using MerkleProof for bytes32[];
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:ethsign.misc.BaseMerkleDistributor
    struct BaseMerkleDistributorStorage {
        mapping(bytes32 leaf => bool used) usedLeafs;
        bytes32 root;
        address deployer;
        address token;
        address claimDelegate;
        uint256 startTime;
        uint256 endTime;
    }

    // keccak256(abi.encode(uint256(keccak256("ethsign.misc.BaseMerkleDistributor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseMerkleDistributorStorageLocation =
        0x452bdf2c9fe836ad357e55ed0859c19d2ac2a2c151d216523e3d37a8b9a03f00;

    event Initialized(string projectId);
    event ClaimDelegateSet(address delegate);
    event Claimed(address recipient, bytes32 group, bytes data);

    error UnsupportedOperation();
    error TimeInactive();
    error InvalidProof();
    error LeafUsed();
    error IncorrectFees();

    modifier onlyDelegate() {
        if (_msgSender() != _getBaseMerkleDistributorStorage().claimDelegate) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
        _;
    }

    modifier onlyActive() {
        if (
            block.timestamp < _getBaseMerkleDistributorStorage().startTime
                || block.timestamp > _getBaseMerkleDistributorStorage().endTime
        ) revert TimeInactive();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        if (block.chainid != 31_337) {
            _disableInitializers();
        }
    }

    function initialize(string memory projectId, address owner_) public initializer {
        __Ownable_init(owner_);
        __ReentrancyGuard_init_unchained();
        _getBaseMerkleDistributorStorage().deployer = _msgSender();
        emit Initialized(projectId);
    }

    function setClaimDelegate(address delegate) external virtual onlyOwner {
        _getBaseMerkleDistributorStorage().claimDelegate = delegate;
        emit ClaimDelegateSet(delegate);
    }

    function claim(
        bytes32[] calldata proof,
        bytes32 group,
        bytes calldata data
    )
        external
        payable
        virtual
        onlyActive
        nonReentrant
    {
        uint256 claimedAmount = _verifyAndClaim(_msgSender(), proof, group, data);
        _afterClaim(_msgSender(), proof, group, data, claimedAmount);
        emit Claimed(_msgSender(), group, data);
    }

    function batchDelegateClaim(
        address[] calldata recipients,
        bytes32[][] calldata proofs,
        bytes32[] calldata groups,
        bytes[] calldata datas
    )
        external
        payable
        virtual
    {
        for (uint256 i = 0; i < recipients.length; i++) {
            delegateClaim(recipients[i], proofs[i], groups[i], datas[i]);
        }
    }

    function delegateClaim(
        address recipient,
        bytes32[] calldata proof,
        bytes32 group,
        bytes calldata data
    )
        public
        payable
        virtual
        onlyDelegate
        onlyActive
        nonReentrant
    {
        uint256 claimedAmount = _verifyAndClaim(recipient, proof, group, data);
        _afterDelegateClaim(_msgSender(), recipient, proof, group, data, claimedAmount);
        emit Claimed(recipient, group, data);
    }

    // solhint-disable no-empty-blocks
    // solhint-disable ordering
    function withdraw(bytes memory extraData) external virtual;

    function getClaimDelegate() external view returns (address) {
        return _getBaseMerkleDistributorStorage().claimDelegate;
    }

    function getRoot() external view returns (bytes32) {
        return _getBaseMerkleDistributorStorage().root;
    }

    function getTime() external view returns (uint256, uint256) {
        return (_getBaseMerkleDistributorStorage().startTime, _getBaseMerkleDistributorStorage().endTime);
    }

    function getToken() external view returns (address) {
        return _getBaseMerkleDistributorStorage().token;
    }

    function getDeployer() external view returns (address) {
        return _getBaseMerkleDistributorStorage().deployer;
    }

    function version() external pure returns (string memory) {
        return "0.3.0";
    }

    function setBaseParams(address token, uint256 startTime, uint256 endTime, bytes32 root) public virtual onlyOwner {
        if (startTime >= endTime) revert UnsupportedOperation();
        _getBaseMerkleDistributorStorage().token = token;
        _getBaseMerkleDistributorStorage().startTime = startTime;
        _getBaseMerkleDistributorStorage().endTime = endTime;
        _getBaseMerkleDistributorStorage().root = root;
    }

    function encodeLeaf(address user, bytes32 group, bytes memory data) public view virtual returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), user, group, data));
    }

    function verify(bytes32[] calldata proof, bytes32 leaf) public view virtual {
        if (isLeafUsed(leaf)) revert LeafUsed();
        if (!proof.verifyCalldata(_getBaseMerkleDistributorStorage().root, leaf)) revert InvalidProof();
    }

    function isLeafUsed(bytes32 leaf) public view virtual returns (bool) {
        return _getBaseMerkleDistributorStorage().usedLeafs[leaf];
    }

    function _verifyAndClaim(
        address recipient,
        bytes32[] calldata proof,
        bytes32 group,
        bytes calldata data
    )
        internal
        virtual
        returns (uint256 claimedAmount);

    function _send(address recipient, address token, uint256 amount) internal virtual;

    function _chargeFees(address payer, uint256 claimedAmount) internal virtual {
        BaseMerkleDistributorStorage storage $ = _getBaseMerkleDistributorStorage();
        IMDCreate2 deployer = IMDCreate2($.deployer);
        address feeCollector = deployer.feeCollectors(address(this));
        if (feeCollector == address(0)) {
            if (msg.value > 0) revert IncorrectFees();
            return;
        }
        uint256 amountToCharge = ITTUFeeCollector(feeCollector).getFee(address(this), claimedAmount);
        if (amountToCharge == 0) {
            if (msg.value > 0) revert IncorrectFees();
            return;
        }
        address feeToken = deployer.feeTokens(address(this));
        if (feeToken == address(0)) {
            if (msg.value != amountToCharge) revert IncorrectFees();
            (bool success, bytes memory data) = feeCollector.call{ value: amountToCharge }("");
            // solhint-disable-next-line custom-errors
            require(success, string(data));
        } else {
            if (msg.value > 0) revert IncorrectFees();
            IERC20(feeToken).safeTransferFrom(payer, feeCollector, amountToCharge);
        }
    }

    function _afterClaim(
        address recipient,
        bytes32[] calldata, // proof
        bytes32, // group
        bytes calldata, // data
        uint256 claimedAmount
    )
        internal
        virtual
    {
        _chargeFees(recipient, claimedAmount);
    }

    function _afterDelegateClaim(
        address delegate,
        address, // recipient
        bytes32[] calldata, // proof
        bytes32, // group
        bytes calldata, // data
        uint256 claimedAmount
    )
        internal
        virtual
    {
        _chargeFees(delegate, claimedAmount);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner { }

    function _getBaseMerkleDistributorStorage() internal pure returns (BaseMerkleDistributorStorage storage $) {
        assembly {
            $.slot := BaseMerkleDistributorStorageLocation
        }
    }
}
