// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Importaciones de OpenZeppelin para seguridad y control de acceso
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interfaz de Chainlink para los Data Feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    // Returns (roundId, answer, startedAt, updatedAt, answeredInRound)
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// Interfaz para obtener los decimales de tokens ERC-20
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/// @title KipuBank - Bóveda Multi-token con Límite Global en USD
/// @author JuanCruzSaladino / Gemini
/**
 * @notice KipuBank permite a usuarios depositar y retirar ETH y tokens ERC-20
 * en bóvedas personales.
 * - El límite global de depósitos `bankCapUSD` se controla en valor USD
 * obtenido a través de Chainlink Data Feeds, con validación de precio caducado.
 * - Se usa `Ownable` para control de acceso administrativo.
 * - Se utiliza `address(0)` como identificador para el token nativo (ETH).
 * - La contabilidad del límite global se realiza usando 6 decimales internos.
 */
contract KipuBank is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constante que representa el token nativo (ETH) en el sistema.
    address private constant ETH_ADDRESS = address(0);
    
    /// @notice Número de decimales utilizados para la contabilidad interna del valor USD (Ej: 6, como USDC).
    uint256 private constant INTERNAL_DECIMALS = 6;
    
    /// @notice Tiempo máximo que se considera válido un precio de Chainlink (1 hora = 3600 segundos).
    uint256 private constant STALE_PRICE_LIMIT = 3600;

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Balances de los usuarios: mapea `Usuario` -> `Token` -> `Cantidad de Token` (en sus decimales nativos).
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice Mapeo de la dirección del token a su Chainlink Data Feed Address.
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;

    /// @notice Contador de depósitos por usuario.
    mapping(address => uint256) private userDepositCount;

    /// @notice Contador de retiros por usuario.
    mapping(address => uint256) private userWithdrawalCount;

    /// @notice Contador total de depósitos del banco.
    uint256 public totalDepositsCount;

    /// @notice Contador total de retiros del banco.
    uint256 public totalWithdrawalsCount;

    /// @notice Valor total actual en USD de todos los activos del banco (en INTERNAL_DECIMALS).
    uint256 private totalBankBalanceUSD;

    /// @notice Límite global máximo de depósitos del banco, expresado en USD (en INTERNAL_DECIMALS).
    uint256 public immutable bankCapUSD;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitido cuando un usuario deposita un activo.
    event DepositMade(address indexed user, address indexed token, uint256 amount, uint256 amountUSD);

    /// @notice Emitido cuando un usuario retira un activo.
    event WithdrawalMade(address indexed user, address indexed token, uint256 amount, uint256 amountUSD);

    /// @notice Emitido cuando se establece o actualiza un Data Feed de precios.
    event PriceFeedUpdated(address indexed token, address indexed feedAddress);

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    error KipuBank_ZeroAmount();
    error KipuBank_BankCapExceeded(uint256 attemptedAmountUSD, uint256 newTotalBalanceUSD, uint256 bankCapUSD);
    error KipuBank_InsufficientBalance(uint256 requested, uint256 available);
    error KipuBank_TransferFailed(address to, uint256 amount);
    error KipuBank_NoPriceFeed();
    error KipuBank_InvalidPrice(int256 price);
    error KipuBank_NotETHAddress();
    /// @notice Emitido cuando el precio de Chainlink está desactualizado (stale).
    error KipuBank_StalePrice(uint256 timeSinceUpdate, uint256 limit);


    /*//////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el banco con un límite global de depósitos en USD.
     * @param _bankCapUSD Límite de depósitos en USD (utilizando 6 decimales).
     */
    // Si incluiste el límite de retiro (withdrawLimitPerTxUSD)
    // DESPUÉS (Llamando a ambos constructores base)
    constructor(uint256 _bankCapUSD) 
      Ownable(msg.sender) 
      ReentrancyGuard() // ¡Esta es la llamada faltante!
    {
      bankCapUSD = _bankCapUSD;
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE / FALLBACK HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maneja depósitos de ETH nativo.
    receive() external payable {
        if (msg.value == 0) revert KipuBank_ZeroAmount();
        _deposit(ETH_ADDRESS, msg.value);
    }

    /// @notice Maneja la llamada a fallback. Solo soporta depósitos de ETH.
    fallback() external payable {
        if (msg.value > 0) {
            _deposit(ETH_ADDRESS, msg.value);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FUNCIONES ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Permite al dueño establecer el Chainlink Data Feed para un token.
     * @param token La dirección del token (use address(0) para ETH).
     * @param feedAddress La dirección del oráculo de Chainlink para ese token.
     */
    function setTokenPriceFeed(address token, address feedAddress) external onlyOwner {
        tokenPriceFeeds[token] = AggregatorV3Interface(feedAddress);
        emit PriceFeedUpdated(token, feedAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Permite al usuario depositar ETH en su bóveda.
     */
    function depositETH() external payable {
        if (msg.value == 0) revert KipuBank_ZeroAmount();
        _deposit(ETH_ADDRESS, msg.value);
    }

    /**
     * @notice Permite al usuario depositar un token ERC-20.
     * @dev Requiere que el usuario apruebe previamente este contrato para gastar `amount`.
     * @param token Dirección del token ERC-20 a depositar.
     * @param amount Cantidad del token a depositar (en sus decimales nativos).
     */
    function depositERC20(address token, uint256 amount) external {
        if (token == ETH_ADDRESS) revert KipuBank_NotETHAddress();
        if (amount == 0) revert KipuBank_ZeroAmount();

        // CHECKS & INTERACTIONS: Transfiere el token desde el usuario al contrato
        // Patrón checks-effects-interactions
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // EFFECTS: Ejecuta la lógica de depósito
        _deposit(token, amount);
    }

    /**
     * @notice Permite al usuario retirar ETH o tokens ERC-20 de su bóveda.
     * @param token Dirección del token a retirar (address(0) para ETH).
     * @param amount Cantidad del token a retirar (en sus decimales nativos).
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert KipuBank_ZeroAmount();

        // CHECKS
        uint256 userBalance = balances[msg.sender][token];
        if (amount > userBalance) revert KipuBank_InsufficientBalance(amount, userBalance);

        // EFFECTS
        // 1. Calcula el valor USD a reducir del límite global
        uint256 amountUSD = _getAssetValueInUSD(token, amount);
        
        unchecked {
            balances[msg.sender][token] = userBalance - amount;
            totalBankBalanceUSD -= amountUSD;
            userWithdrawalCount[msg.sender] += 1;
            totalWithdrawalsCount += 1;
        }

        // INTERACTIONS
        if (token == ETH_ADDRESS) {
            // Transferencia segura de ETH nativo
            _safeTransfer(payable(msg.sender), amount);
        } else {
            // Transferencia segura de token ERC-20
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit WithdrawalMade(msg.sender, token, amount, amountUSD);
    }

    /*//////////////////////////////////////////////////////////////
                                PRIVATE / INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lógica privada de depósito que maneja la verificación del límite global.
     * @param token Dirección del token depositado (address(0) para ETH).
     * @param amount Cantidad depositada (en decimales nativos del token).
     */
    function _deposit(address token, uint256 amount) private {
        // CHECKS
        uint256 amountUSD = _getAssetValueInUSD(token, amount);
        uint256 newTotalUSD = totalBankBalanceUSD + amountUSD;

        if (newTotalUSD > bankCapUSD) revert KipuBank_BankCapExceeded(amountUSD, newTotalUSD, bankCapUSD);

        // EFFECTS (Patrón checks-effects-interactions)
        unchecked {
            balances[msg.sender][token] += amount;
            totalBankBalanceUSD = newTotalUSD;
            userDepositCount[msg.sender] += 1;
            totalDepositsCount += 1;
        }

        // NO INTERACTION (La transferencia ya se hizo en receive/fallback o depositERC20)
        emit DepositMade(msg.sender, token, amount, amountUSD);
    }
    
    /**
     * @notice Obtiene el valor en USD de una cantidad de token usando Chainlink Data Feed.
     * @param token La dirección del token (address(0) para ETH).
     * @param amount Cantidad del token (en sus decimales nativos).
     * @return El valor en USD de la cantidad (en INTERNAL_DECIMALS).
     */
    function _getAssetValueInUSD(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = tokenPriceFeeds[token];
        if (address(priceFeed) == address(0)) revert KipuBank_NoPriceFeed();

        // Obtiene el precio (roundId, answer, startedAt, updatedAt, answeredInRound)
        (
            /* roundId */,
            int256 price,
            /* startedAt */,
            uint256 updatedAt,
            /* answeredInRound */
        ) = priceFeed.latestRoundData();

        // 🟢 MODIFICACIÓN: SEGURIDAD - Validar que el precio no esté caducado
        if (updatedAt < block.timestamp - STALE_PRICE_LIMIT) {
            revert KipuBank_StalePrice(block.timestamp - updatedAt, STALE_PRICE_LIMIT);
        }

        if (price <= 0) revert KipuBank_InvalidPrice(price);

        // Escalado a 256 bits para evitar overflows intermedios
        uint256 priceFeedDecimals = priceFeed.decimals();
        uint256 tokenDecimals = token == ETH_ADDRESS ? 18 : IERC20Metadata(token).decimals();
        
        // 1. Convertir la cantidad al valor en USD y escalar a 18 decimales
        // Formula: (amount * price * 10^(18 - priceFeedDecimals)) / (10^tokenDecimals)
        uint256 valueInUSD18 = (amount * uint256(price) * (10**(18 - priceFeedDecimals))) / (10**tokenDecimals);
        
        // 2. Escalar de 18 decimales al estándar interno (6 decimales)
        // Formula: valueInUSD18 / (10^(18 - INTERNAL_DECIMALS))
        uint256 valueInUSDInternalDecimals = valueInUSD18 / (10**(18 - INTERNAL_DECIMALS));

        return valueInUSDInternalDecimals;
    }

    /**
     * @notice Función de bajo nivel para enviar ETH.
     * @dev Utiliza `call` para una transferencia segura de ETH.
     * @param to Dirección de destino.
     * @param amount Cantidad de ETH a enviar (en wei).
     */
    function _safeTransfer(address payable to, uint256 amount) private {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert KipuBank_TransferFailed(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                   VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retorna el balance de un usuario para un token específico.
     * @param user La dirección del usuario.
     * @param token La dirección del token (address(0) para ETH).
     * @return balance El balance de token (en sus decimales nativos).
     */
    function getBalance(address user, address token) external view returns (uint256 balance) {
        return balances[user][token];
    }

    /**
     * @notice Retorna el balance total actual del banco en USD.
     * @return bankBalanceUSD El valor total del banco en USD (en INTERNAL_DECIMALS).
     */
    function getTotalBankBalanceUSD() external view returns (uint256 bankBalanceUSD) {
        return totalBankBalanceUSD;
    }

    /**
     * @notice Retorna las estadísticas globales de depósitos y retiros.
     * @return totalDeposits El número total de depósitos realizados.
     * @return totalWithdrawals El número total de retiros realizados.
     */
    function getGlobalStats() external view returns (uint256 totalDeposits, uint256 totalWithdrawals) {
        return (totalDepositsCount, totalWithdrawalsCount);
    }

    /**
     * @notice Retorna las estadísticas de depósitos y retiros para un usuario.
     * @param user La dirección del usuario.
     * @return deposits El número de depósitos hechos por el usuario.
     * @return withdrawals El número de retiros hechos por el usuario.
     */
    function getUserStats(address user) external view returns (uint256 deposits, uint256 withdrawals) {
        return (userDepositCount[user], userWithdrawalCount[user]);
    }
}