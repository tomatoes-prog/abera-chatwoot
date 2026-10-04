class Abera::OperationReceipt < ApplicationRecord
  self.table_name = 'abera_operation_receipts'
  serialize :credentials, coder: JSON
  encrypts :credentials
end
