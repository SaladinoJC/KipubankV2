# KipuBankV2
Este documento detalla las mejoras realizadas al contrato original de KipuBank, transformándolo en una bóveda multi-token lista para entornos de producción.
## Mejoras de la Versión v2.1 (Visión General)

La actualización clave fue pasar de un sistema de depósito/límite en wei (ETH nativo) a un sistema de contabilidad global en USD (bankCapUSD), habilitando la gestión de múltiples activos (ETH y ERC-20).

- **Soporte Multi-Token**: 	Mapeo anidado (Usuario -> Token -> Balance).	Permite que el banco no solo gestione ETH, sino cualquier activo ERC-20, diversificando la bóveda.
- **Límite Global en USD** :	Uso de bankCapUSD (immutable) y rastreo de totalBankBalanceUSD.	Proporciona una métrica de riesgo estable e independiente de la volatilidad del precio de ETH.
- **Integración Chainlink**	Uso de AggregatorV3Interface y la función _getAssetValueInUSD.	Obteniene precios en tiempo real de forma descentralizada y segura para validar el límite USD.
- **Seguridad de Acceso**	Herencia de Ownable y restricción a setTokenPriceFeed.	Implementa el control de acceso estándar para proteger funciones críticas de configuración.
- **Seguridad Operacional**	Herencia de ReentrancyGuard y uso de SafeERC20.	Mitiga ataques de reentrada en retiros y asegurar interacciones correctas con contratos de token.

---

## Decisiones de Diseño Importantes (Trade-offs)
Al migrar a una arquitectura multi-token y USD, se tomaron las siguientes decisiones fundamentales:
### 1-Contabilidad de decimales
- **Estándar Interno de 6 Decimales**: Se eligió 6 (INTERNAL_DECIMALS) para la contabilidad de totalBankBalanceUSD.
Pros: El estándar de $6$ decimales es común para stablecoins (como USDC), facilitando la gestión de riesgos.
Contras: La conversión en _getAssetValueInUSD es compleja y consume más gas, ya que debe manejar las diferencias entre los decimales del token y la escala final.
- **address(0) para ETH**: Se usa la dirección nula (0x0...0) como identificador de token dentro de los mappings del banco.
Pros: Simplifica la lógica de contabilidad de la bóveda. 
Contras: Requiere un check explícito en cada función para diferenciar la lógica de transferencia de ETH (nativo) frente a ERC-20 (contrato).

### 2-Seguridad de Chainlink
- **Validación de Precio Caducado**: Se implementa un check de updatedAt y STALE_PRICE_LIMIT (3600 segundos) en _getAssetValueInUSD.
Alto Impacto: Esto evita que un atacante deposite o retire grandes cantidades utilizando un precio de mercado obsoleto, protegiendo la solvencia del bankCapUSD.


#### Despliegue e Interacción (Sepolia)

1. Abrir [Remix IDE](https://remix.ethereum.org/).
2. Crear un archivo en la carpeta `contracts/` llamado `KipuBankv2.sol` y pegar el código del contrato.
3. Compilar:
   - Ir a la pestaña **Solidity Compiler**.
   - Seleccionar versión `0.8.30`.
   - Compilar el contrato.
4. Desplegar:
   - Ir a la pestaña **Deploy & Run Transactions**.
   - En **Environment**, seleccionar **Injected Provider - MetaMask** (esto conecta Remix con tu MetaMask).
   - Verifica que la red sea **Sepolia Testnet** en MetaMask.
   - En el formulario de despliegue, ingresar los parámetros del constructor:
     - `bankCap`: límite global de depósitos
   - Hacer click en **Deploy** y confirmar la transacción en MetaMask.
5. Una vez desplegado, verás el contrato en la sección **Deployed Contracts** de Remix.
6. Configuración Inicial Obligatoria:
   - Después del despliegue, el Owner debe llamar a setTokenPriceFeed para que el banco pueda recibir depósitos de ETH.
7. Interactúa con las funciones:
   -Interacción: Depositar ETH y Tokens ERC-20
      -depositETH: ETH nativo  ->  Llamar a la función (depositETH) y adjuntar el valor en ETH a la transacción.
      -depositERC20: Token ERC-20
                                    1. Aprobar: Llamar a approve en el Contrato del Token para dar permiso a KipuBank. 
                                    2. Depositar: Llamar a depositERC20([Token Address], [Amount en decimales nativos]) en KipuBank.
