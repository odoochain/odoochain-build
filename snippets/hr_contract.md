---
prev: ./snippets.md
---
# Hr Contract
## Hr Contract View Kanban  
### Show Start Date  
ID: `mint_system.hr_contract.hr_contract_view_kanban.show_start_date`  
```xml
<?xml version="1.0"?>
<data inherit_id="hr_contract.hr_contract_view_kanban" priority="50">

  <xpath expr="//field[@name='job_id']" position="after">
    <br/><field name="date_start"/>
  </xpath>

</data>
```

Source: [snippets/hr_contract.hr_contract_view_kanban.show_start_date.xml](https://github.com/Mint-System/Odoo-Development/tree/14.0/snippets/hr_contract.hr_contract_view_kanban.show_start_date.xml)

