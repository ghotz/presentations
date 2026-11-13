SELECT
    o.name                          AS json_index_internal_table,
    o.type_desc,
    SUM(a.total_pages) * 8          AS total_kb,
    SUM(a.used_pages)  * 8          AS used_kb,
    SUM(a.data_pages)  * 8          AS data_kb
FROM sys.objects o
JOIN sys.partitions p   ON o.object_id = p.object_id
JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE o.name LIKE '%json%'   -- adatta il filtro al nome effettivo
GROUP BY o.name, o.type_desc;