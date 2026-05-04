cd "E:\OneDrive\Documents\Presentations\UGISS\2025-2029\20260418 Global Azure Pordenone\Demos"
ostress.exe ^
  -S"ugissdemo.database.windows.net" ^
  -d"ugissperf" ^
  -U"ghotz" -P"INSERTPASSWORD" ^
  -i"workload.sql" ^
  -o"ostress-ugissperf" ^
  -n30 ^
  -r1000 ^
  -q
pasue