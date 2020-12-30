# Guide:

In repository root:

1. Install the dependencies with npm or yarn: `yarn install`

2. Go to `scripts/deployment-testnet`

3. Edit the `.env.example` with your parameters and save it as `.env`
   The account of the mnemonic derived from the the path `m/44'/60'/0'/0` will deploy all the contracts, be assure that has enough ether.
   All parameters are required, except for the `ETHERSCAN_API_KEY` wich it's only use is for verify the contracts, wich is an optional step.

4. Edit the `deploy_parameters.json`
   The json contains all the deployment parameters, indexed with a `chainID`.
   You can set the libraries that are already deployed (if the field is empty will be deployed). Also the contructor parameters of all smart contracts and finally the `tokens` field wich are the address of the tokens that will be automatically added to the Hermez at the end of the deployment

5. Run the deployment script:`node deploy.js`

> Be aware that a `.openzeppelin` folder will be created. That folder it's usefull in case of redeployment of the contracts because the logic (or implementation) contract can be reused as a libreary and only a new proxy contract will be deployed.

6. (optional) Verify the smart contracts in etherscan!
   For this step a `ETHERSCAN_API_KEY` must be provided in the .env file, contracts must be deployed and the `.openzeppelin` must be created.
   Be aware that once the contracts are verified in a chain, etherscan recognizes them and there's no need to verify them again. So this process should only be used once. That's why also there's no need to verify the proxy contract.
   Due a bug of the buidler plugin, more contracts than jsut the source of the implementation are pushed to the verification, allowing etherescan to verify the contract and allowing users to "read" the data of the transactions, but it's messy if some user want to read the smart contract from here.
   That's why in mainet this process will be done manually to assure the polite correctness of the verifications

   - Run `node verifyContracts`