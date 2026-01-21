# Multi-line version:
az network application-gateway waf-policy managed-rule exception add \
  --resource-group EBSAPP-GATEWAY \
  --policy-name EBS-WAFPolicy \
  --match-variable RequestURI \
  --value-operator Contains \
  --values "app/modules/ajaxgrid/ajaxgridactions.ashx" \
  --rule-sets '[{
    "ruleSetType": "OWASP",
    "ruleSetVersion": "3.2",
    "ruleGroups": [{"ruleGroupName": "REQUEST-942-APPLICATION-ATTACK-SQLI"}]
  }]'

# Single-line version (alternative):
az network application-gateway waf-policy managed-rule exception add --resource-group EBSAPP-GATEWAY --policy-name EBS-WAFPolicy --match-variable RequestURI --value-operator Contains --values "app/modules/ajaxgrip/ajaxgridactions.ashx" --rule-sets '[{"ruleSetType": "OWASP", "ruleSetVersion": "3.2", "ruleGroups": [{"ruleGroupName": "REQUEST-942-APPLICATION-ATTACK-SQLI"}]}]'

# Example with specific rule ID (942420):
az network application-gateway waf-policy managed-rule exception add \
  --resource-group EBSAPP-GATEWAY \
  --policy-name EBS-WAFPolicy \
  --match-variable RequestURI \
  --value-operator Contains \
  --values "app/modules/ajaxgrid/ajaxgridactions.ashx" \
  --rule-sets '[{
    "ruleSetType": "OWASP",
    "ruleSetVersion": "3.2",
    "ruleGroups": [{"ruleGroupName": "REQUEST-942-APPLICATION-ATTACK-SQLI", "rules": [{"ruleId": "942420"}]}]
  }]'

# Single-line version with specific rule:
az network application-gateway waf-policy managed-rule exception add --resource-group EBSAPP-GATEWAY --policy-name EBS-WAFPolicy --match-variable RequestURI --value-operator Contains --values "app/modules/ajaxgrip/ajaxgridactions.ashx" --rule-sets '[{"ruleSetType": "OWASP", "ruleSetVersion": "3.2", "ruleGroups": [{"ruleGroupName": "REQUEST-942-APPLICATION-ATTACK-SQLI", "rules": [{"ruleId": "942420"}]}]}]'   

# List all exceptions in the WAF policy
az network application-gateway waf-policy managed-rule exception list --policy-name EBS-WAFPolicy --resource-group EBSAPP-GATEWAY