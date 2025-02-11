------------------------------------------------------------------------
-- Copyright:   2018 Gianluca Hotz
-- License:     MIT License
--              Permission is hereby granted, free of charge, to any
--              person obtaining a copy of this software and associated
--              documentation files (the "Software"), to deal in the
--              Software without restriction, including without
--              limitation the rights to use, copy, modify, merge,
--              publish, distribute, sublicense, and/or sell copies of
--              the Software, and to permit persons to whom the
--              Software is furnished to do so, subject to the
--              following conditions:
--              The above copyright notice and this permission notice
--              shall be included in all copies or substantial portions
--              of the Software.
--              THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
--              ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
--              LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
--              FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
--              EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
--              FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
--              AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--              OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
--              OTHER DEALINGS IN THE SOFTWARE.
--              This script needs to be run on the source system.
-- Credits:     
------------------------------------------------------------------------
USE master
GO

-- creiamo un database per effettuare le prove
IF EXISTS(SELECT * FROM sys.databases WHERE name = 'SecurityTest')
	DROP DATABASE SecurityTest
GO
CREATE DATABASE SecurityTest
GO

-- creiamo una tabella che contiene dati sensibili
USE SecurityTest
CREATE TABLE dbo.AccountsTable (
	Id		int				NOT NULL
,	AccName	nvarchar(30)	NOT NULL
,	Dept	varchar(20)		NOT NULL
,	Pay_Num	varbinary(60)	NOT NULL

,	CONSTRAINT	pkAccountsTable
	PRIMARY KEY	(Id)
)
GO

-- il primo metodo per cifrare utilizza semplicemente una
-- chiave simmetrica che viene passata ad una funzione T-SQL
-- e deve quindi essere mantenuta esternamente al database
INSERT	dbo.AccountsTable
VALUES	(1, 'Susan', 'HR', EncryptByPassPhrase('Very Complex Simmetric Key', '1500'))

INSERT	dbo.AccountsTable
VALUES	(2, 'Richard', 'Sales', EncryptByPassPhrase('Very Complex Simmetric Key', '2000'))

INSERT	dbo.AccountsTable
VALUES	(3, 'Leah', 'Purchasing', EncryptByPassPhrase('Very Complex Simmetric Key', '2600'))
GO

-- se proviamo a selezionare, i valori sono cifrati
SELECT * FROM dbo.AccountsTable
GO

-- per renderli visibili dobbiamo decifrarli specificando
-- la stessa chiave simmetrica utilizzata per cifrarli
SELECT	Id
,		AccName
,		Dept
,		CAST(
			DecryptByPassPhrase('Very Complex Simmetric Key', Pay_Num)
		AS varchar) AS Pay_Num
FROM	dbo.AccountsTable
GO

-- pulizia
TRUNCATE TABLE dbo.AccountsTable
GO

-- il secondo metodo consiste generare una chiave simmetrica
-- complessa ed archiviarla in SQL Server protetta da una password
CREATE	SYMMETRIC KEY SymKeyWithPWD
WITH	ALGORITHM = TRIPLE_DES
ENCRYPTION BY PASSWORD = 'ComPLeXP@ssw0rd'
GO

-- i dati relativi alle chiavi simmetriche possono essere
-- visualizzati tramite opportune viste di catalogo
SELECT * FROM sys.symmetric_keys
GO

-- apriamo la chiave specificando la password che la protegge
OPEN SYMMETRIC KEY SymKeyWithPWD
DECRYPTION BY PASSWORD = 'ComPLeXP@ssw0rd'

-- a questo punto possiamo utilizzarla per cifrare i dati
INSERT	dbo.AccountsTable
VALUES	(1, 'Susan', 'HR', EncryptByKey(Key_GUID('SymKeyWithPWD'), '1500'))

INSERT	dbo.AccountsTable
VALUES	(2, 'Richard', 'Sales', EncryptByKey(Key_GUID('SymKeyWithPWD'), '2000'))

INSERT	dbo.AccountsTable
VALUES	(3, 'Leah', 'Purchasing', EncryptByKey(Key_GUID('SymKeyWithPWD'), '2600'))

-- se proviamo a selezionare, i valori sono cifrati
SELECT * FROM dbo.AccountsTable
GO

-- dobbiamo decifrarli tramite la chiave che abbiamo
-- precedentemente aperto
SELECT	Id
,		AccName
,		Dept
,		CAST(
			DecryptByKey(Pay_Num)
		AS varchar) AS Pay_Num
FROM	dbo.AccountsTable
GO

-- possiamo visualizzare le chiavi aperte tramite
-- un'opportuna vista di catalogo
SELECT * FROM sys.openkeys
GO

-- quando abbiamo finito di utilizzare una chiave
-- possiamo chiuderla
CLOSE SYMMETRIC KEY SymKeyWithPWD
GO

-- una chiave puo' essere eliminata in qualunque momento
-- tramite il seguente comando
DROP SYMMETRIC KEY SymKeyWithPWD
GO

-- asymetric and certificate are quite simple too,
-- let's move to a more complex example

-- cifrare con una chiave asimmetrica e' molto simile
-- proviamo a fare un esempio piu' complesso

-- pulizia
TRUNCATE TABLE dbo.AccountsTable
GO

-- creiamo due nuovi utenti
IF EXISTS(SELECT * FROM sys.sql_logins WHERE name = 'Sophie')
	DROP LOGIN Sophie
IF EXISTS(SELECT * FROM sys.sql_logins WHERE name = 'Alison')
	DROP LOGIN Alison
GO
CREATE LOGIN Sophie WITH PASSWORD = 'Passw0rd'
CREATE LOGIN Alison WITH PASSWORD = 'Passw0rd'
GO

-- creiamo gli utenti nel nuovo database
CREATE USER Sophie FOR LOGIN Sophie
CREATE USER Alison FOR LOGIN Alison
GO

-- assegniamo i permessi per poter selezionare e inserire
-- nella tabella ai due nuovi utenti
GRANT SELECT, INSERT ON dbo.AccountsTable TO Sophie
GRANT SELECT, INSERT ON dbo.AccountsTable TO Alison
GO

-- creiamo la database master key
CREATE MASTER KEY
ENCRYPTION BY PASSWORD = 'Passw0rd'
GO

-- creiamo un certificato di prorieta' di Sophie
CREATE CERTIFICATE SophieAccountCertificate
AUTHORIZATION Sophie WITH
	SUBJECT = 'SophieAccountCertificate'
,	START_DATE = '20051107'

-- creiamo un certificato di prorieta' di Alison
CREATE CERTIFICATE AlisonAccountCertificate
AUTHORIZATION Alison WITH
	SUBJECT = 'AlisonAccountCertificate'
,	START_DATE = '20051107'
GO

-- creiamo una chiave simmetrica di proprieta' di
-- Sophie protetto tramite il suo certificato
CREATE SYMMETRIC KEY SophieAccountKey
AUTHORIZATION Sophie
WITH ALGORITHM = TRIPLE_DES
ENCRYPTION BY CERTIFICATE SophieAccountCertificate

-- creiamo una chiave simmetrica di proprieta' di
-- Alison protetto tramite il suo certificato
CREATE SYMMETRIC KEY AlisonAccountKey
AUTHORIZATION Alison
WITH ALGORITHM = TRIPLE_DES
ENCRYPTION BY CERTIFICATE AlisonAccountCertificate
GO

-- verifichiamo tramite le viste di catalogo le chiavi
-- ed i certificati (nota: i certificati sono protetti dalla
-- master database key)
SELECT * FROM sys.symmetric_keys
SELECT * FROM sys.certificates
GO

-- Sophie inizia aprendo la sua chiave simmetrica
-- utilizzando il suo certificato
EXECUTE AS USER = 'Sophie'

OPEN SYMMETRIC KEY	SophieAccountKey
DECRYPTION BY CERTIFICATE	SophieAccountCertificate

REVERT
GO

-- verifichiamo che la chiave sia aperta
SELECT * FROM sys.openkeys

-- Sophie inserisce alcuni dati cifrandone una parte
EXECUTE AS USER = 'Sophie'

INSERT	dbo.AccountsTable
VALUES	(1, 'Susan', 'HR', EncryptByKey(Key_GUID('SophieAccountKey'), '1500'))

INSERT	dbo.AccountsTable
VALUES	(2, 'Richard', 'Sales', EncryptByKey(Key_GUID('SophieAccountKey'), '2000'))

INSERT	dbo.AccountsTable
VALUES	(3, 'Leah', 'Purchasing', EncryptByKey(Key_GUID('SophieAccountKey'), '2600'))

-- quando ha terminato chiude la sua chiave simmetrica
CLOSE ALL SYMMETRIC KEYS

REVERT
GO

-- anche Alison apre la sua chive ed inserisce alcuni dati
-- cifrandone una parte
EXECUTE AS USER = 'Alison'

OPEN SYMMETRIC KEY	AlisonAccountKey
DECRYPTION BY CERTIFICATE	AlisonAccountCertificate

INSERT	dbo.AccountsTable
VALUES	(4, 'Tim', 'HR', EncryptByKey(Key_GUID('AlisonAccountKey'), '7000'))

INSERT	dbo.AccountsTable
VALUES	(5, 'David', 'Sales', EncryptByKey(Key_GUID('AlisonAccountKey'), '4500'))

INSERT	dbo.AccountsTable
VALUES	(6, 'Leah', 'Celia', EncryptByKey(Key_GUID('AlisonAccountKey'), '3444'))

CLOSE ALL SYMMETRIC KEYS

REVERT
GO

-- se proviamo a selezionare, i valori sono cifrati
SELECT * FROM dbo.AccountsTable
GO

-- Sophie apre la sua chiave simmetrica tramite il
-- suo certificato ed e' in grado di decifrare solo
-- i dati che ha cifrato con quella chiave
EXECUTE AS USER = 'Sophie'

OPEN SYMMETRIC KEY	SophieAccountKey
DECRYPTION BY CERTIFICATE	SophieAccountCertificate

SELECT	Id
,		AccName
,		Dept
,		CAST(DecryptByKey(Pay_Num) AS varchar) AS Pay_Num
FROM	dbo.AccountsTable

CLOSE ALL SYMMETRIC KEYS

REVERT
GO

-- in maniera analoga, Alison puo' decifrare solo i dati
-- che ha cifrato con la sua chiave
EXECUTE AS USER = 'Alison'

OPEN SYMMETRIC KEY	AlisonAccountKey
DECRYPTION BY CERTIFICATE	AlisonAccountCertificate

SELECT	Id
,		AccName
,		Dept
,		CAST(DecryptByKey(Pay_Num) AS varchar) AS Pay_Num
FROM	dbo.AccountsTable

CLOSE ALL SYMMETRIC KEYS

REVERT
GO

-- Sophie non puo' aprire la chiave di Alison
EXECUTE AS USER = 'Sophie'

OPEN SYMMETRIC KEY	AlisonAccountKey
DECRYPTION BY CERTIFICATE	AlisonAccountCertificate

SELECT	Id
,		AccName
,		Dept
,		CAST(DecryptByKey(Pay_Num) AS varchar) AS Pay_Num
FROM	dbo.AccountsTable

REVERT
GO

-- se assegniamo a Sophie i permessi per controllare il certificato
-- e la chiave di Alison...
GRANT CONTROL ON CERTIFICATE::AlisonAccountCertificate TO Sophie
GRANT CONTROL ON SYMMETRIC KEY::AlisonAccountKey TO Sophie
GO

-- ... allora Sophie potra' aprire la chiave di Alison
EXECUTE AS USER = 'Sophie'

OPEN SYMMETRIC KEY	AlisonAccountKey
DECRYPTION BY CERTIFICATE	AlisonAccountCertificate

SELECT	Id
,		AccName
,		Dept
,		CAST(DecryptByKey(Pay_Num) AS varchar) AS Pay_Num
FROM	dbo.AccountsTable

REVERT
GO

-- si puo' fare il backup dei certificati
BACKUP CERTIFICATE AlisonAccountCertificate
TO FILE = 'AlisonCertificate.cer'
