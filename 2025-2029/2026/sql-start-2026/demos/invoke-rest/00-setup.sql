use tempdb
go

exec sp_configure 'external rest endpoint enabled', 1
reconfigure;
go