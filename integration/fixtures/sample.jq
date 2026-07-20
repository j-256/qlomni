# Sum the .value field across records with status == "active"
def active: map(select(.status == "active"));

.records
| active
| map(.value)
| add // 0
