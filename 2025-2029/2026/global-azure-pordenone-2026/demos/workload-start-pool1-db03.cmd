cd "E:\OneDrive\Documents\Presentations\UGISS\2025-2029\20260418 Global Azure Pordenone\Demos\"
ostress.exe ^
  -S"ugissdemo.database.windows.net" ^
  -d"db03" ^
  -U"ghotz" -P"INSERTPASSWORD" ^
  -i"workload.sql" ^
  -o"ostress-pool1-db03" ^
  -n10 ^
  -r50 ^
  -q
pause