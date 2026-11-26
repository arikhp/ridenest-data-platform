-- Run ONCE (use Run All) in the Snowflake trial QKVPWRB-GB28666 (AWS Zurich), as ACCOUNTADMIN,
-- in a Snowsight worksheet. Creates the service user Terraform logs in with.
-- The public key below is safe to commit; the private key stays in ~/.snowflake/keys/.
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS TERRAFORM_SVC
  TYPE = SERVICE
  RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAybq1pbS3DL/9R6sIWEImLQql9TaTI/cqnMGXhi9g2JeRQCl6MlezEmq4H/73Grh4MYzwYD1ry7CwxLlZaS1o7AmrFisNXauqlhIQswiMxXjtpMfpE9CzPM+tZCSDhsYvUuz2Cgwhq//LxVNNCefhx/f2U8xTsXpnG2ilwiGJuKx9YIxDwSMP2NPGcfj1MEcxAWoq2ibCJk1GHsNGs2Y0CV65AQ/Mn4xaO+ihO0KoYz3ho79aQBC0exbNZh9T+1EeuNG5pue9a+36Qk1HitUxVsl5LwJg5pcc51UBgjzc/7gaE6PH54nZqNRDabx5SMuRNjYSsVLIZybYzkCwQV9o2QIDAQAB'
  DEFAULT_ROLE = ACCOUNTADMIN
  COMMENT = 'RideNest Terraform (all envs)';

GRANT ROLE ACCOUNTADMIN TO USER TERRAFORM_SVC;

-- Paste these two values back to Claude:
SELECT CURRENT_ORGANIZATION_NAME() AS organization_name, CURRENT_ACCOUNT_NAME() AS account_name;
