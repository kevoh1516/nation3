// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@rari-capital/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import {IVotingEscrow} from "../governance/IVotingEscrow.sol";
import {Passport} from "./Passport.sol";

/// @notice Issues membership tokens when locking ERC20 tokens
/// @author Nation3 (https://github.com/nation3)
/// @dev Only issues new passports to not already issued accounts
contract PassportIssuer is Initializable, Ownable {
    /*///////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeTransferLib for ERC20;
    using SafeTransferLib for IVotingEscrow;

    /*///////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotEligible();
    error NonRevocable();
    error InvalidSignature();
    error PassportAlreadyIssued();
    error PassportNotIssued();
    error IssuanceIsDisabled();
    error IssuancesLimitReached();

    /*///////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Issue(address indexed account, uint256 indexed passportId);
    event Withdraw(address indexed amount, uint256 indexed passportId);

    /*///////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The token used to lock.
    IVotingEscrow public veToken;
    /// @notice The token that issues.
    Passport public passToken;

    /// @notice Status of the passport issance.
    bool public enabled;

    /// @notice Limit of passports to issue, cannot be change after initialization.
    uint256 public maxIssuances;
    /// @notice Number of passports issued.
    uint256 public totalIssued;
    /// @notice Balance of veToken required to claim.
    uint256 public claimRequiredBalance;
    /// @notice Balance of veToken under which a passport is revocable.
    uint256 public revokeUnderBalance;

    /// @notice Agreement statement to sign before claim.
    string public statement;
    /// @notice Agreement terms URL to sign before claim.
    string public termsURI;

    /// @dev Domain separator hash on initialization.
    bytes32 internal INITIAL_DOMAIN_SEPARATOR;

    /// @dev Map the passport status of an account.
    /// @dev 0 -> Not issued
    /// @dev 1 -> Issued
    /// @dev 2 -> Withdrawn
    mapping(address => uint8) internal _status;
    /// @dev Passport id issued by account.
    mapping(address => uint256) internal _passportId;

    /*///////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Requires to be enabled before performing function.
    modifier isEnabled() {
        if (!enabled) revert IssuanceIsDisabled();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                               INITIALITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets tokens and supply.
    /// @param _veToken Lock token which balance is required to claim.
    /// @param _passToken NFT token to mint.
    /// @param _maxIssuances Maxi number of tokens that can be issued with this contract.
    function initialize(
        IVotingEscrow _veToken,
        Passport _passToken, 
        uint256 _maxIssuances
    ) public initializer {
        veToken = _veToken;
        passToken = _passToken;
        maxIssuances = _maxIssuances;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*///////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the status of an account: (0) Not issued, (1) Issued, (2) Withdrawn.
    function passportStatus(address account) public view virtual returns (uint8) {
        return _status[account];
    }

    /// @notice Returns passport id of a given account.
    /// @param account Holder account of a passport.
    /// @dev Revert if the account has no passport.
    function passportId(address account) public view virtual returns (uint256) {
        if (_status[account] == 0) revert PassportNotIssued();
        return _passportId[account];
    }

    /*///////////////////////////////////////////////////////////////
                                USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Issues a new passport token with signature validation.
    function claim(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual isEnabled {
        if (totalIssued >= maxIssuances) revert IssuancesLimitReached();
        if (_status[msg.sender] > 0) revert PassportAlreadyIssued();
        if (veToken.balanceOf(msg.sender) < claimRequiredBalance) revert NotEligible();
        verifySignature(v, r, s);

        _issue(msg.sender);
    }

    /// @notice Removes the passport of the `msg.sender`
    function withdraw() public virtual {
        _withdraw(msg.sender);
    }

    /// @notice Removes the passport of a given account if it's not eligible anymore.
    function revoke(address account) public virtual {
        if (veToken.balanceOf(account) >= revokeUnderBalance) revert NonRevocable();
        _withdraw(account);
    }

    /*///////////////////////////////////////////////////////////////
                              ADMIN ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set requirements to claim & revoke.
    /// @param _claimRequiredBalance Minimum amount of voting escrow tokens required for a new issuance.
    function setParams(
        uint256 _claimRequiredBalance,
        uint256 _revokeUnderBalance
    ) public virtual onlyOwner {
        claimRequiredBalance = _claimRequiredBalance;
        revokeUnderBalance = _revokeUnderBalance;
    }

    /// @notice Updates issuance status.
    /// @dev Can be used by the owner to halt the issuance of new passports.
    function setEnabled(bool status) public virtual onlyOwner {
        enabled = status;
    }

    /// @notice Sets the statement of the issuance agreement.
    function setStatement(string memory _statement) public virtual onlyOwner {
        statement = _statement;
    }

    /// @notice Sets the terms URI of the issuance agreement.
    function setTermsURI(string memory _termsURI) public virtual onlyOwner {
        termsURI = _termsURI;
    }

    /// @notice Allows the owner to remove the passport of any account
    function adminRevoke(address account) public virtual onlyOwner {
        _withdraw(account);
    }

    /// @notice Allows the owner to withdraw any ERC20 sent to the contract.
    /// @param token Token to withdraw.
    /// @param to Recipient address of the tokens.
    function recoverTokens(
        ERC20 token, address to
    ) external virtual onlyOwner returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
    }

    /*///////////////////////////////////////////////////////////////
                             EIP-712 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the domain separator hash for EIP-712 signature.
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return INITIAL_DOMAIN_SEPARATOR != "" ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    /// @notice Verify if sender is signer of contract agreement following EIP-712.
    /// @dev Reverts on signature missmatch.
    function verifySignature(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        // Unchecked because no math here
        unchecked {
            address signer = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256("Agreement(string statement,string termsURI)"),
                                keccak256(abi.encodePacked(statement)),
                                keccak256(abi.encodePacked(termsURI))
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            if (signer != msg.sender) revert InvalidSignature();
        }
    }

    // @dev Compute the EIP-712 domain's separator of the contract.
    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("PassportIssuer")),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*///////////////////////////////////////////////////////////////
                             INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints a new passport token for the recipient.
    /// @param recipient Address to issue the passport to.
    function _issue(address recipient) internal virtual {
        // Mint a new passport to the recipient account
        uint256 tokenId = passToken.safeMint(recipient);

        // Realistically won't overflow;
        unchecked {
            totalIssued++;
        }

        _status[recipient] = 1;
        _passportId[recipient] = tokenId;

        emit Issue(recipient, tokenId);
    }

    /// @dev Burns the passport token of the account & transfer back the locked tokens.
    /// @param account Address of the account to withdraw the passport from.
    function _withdraw(address account) internal virtual {
        uint256 tokenId = passportId(account);

        // Burn passport
        passToken.burn(tokenId);

        _status[account] = 2;
        delete _passportId[account];

        emit Withdraw(account, tokenId);
    }
}
