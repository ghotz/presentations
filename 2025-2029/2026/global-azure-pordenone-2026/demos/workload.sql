-- ============================================================
-- Workload Simulator for AdventureWorksLT on Azure SQL Database
-- Schema: SalesLT (versione lightweight)
-- ============================================================

SET NOCOUNT ON;

DECLARE
    @Iterations     INT = 10000,
    @DelayMs        INT = 50,
    @EnableWrites   BIT = 1,
    @PrintProgress  BIT = 1;

DECLARE
    @i              INT = 0,
    @rnd            INT,
    @CustomerID     INT,
    @ProductID      INT,
    @Delay          VARCHAR(12);

DROP TABLE IF EXISTS #WorkloadLog;
CREATE TABLE #WorkloadLog (
    IterationID     INT,
    OperationType   VARCHAR(30),
    RowsAffected    INT,
    RecordedAt      DATETIME2 DEFAULT SYSDATETIME()
);

WHILE @i < @Iterations
BEGIN
    SET @i  += 1;
    SET @rnd = @i % 10;

    -- --------------------------------------------------------
    -- 1. SELECT: ordini con dettaglio e prodotto (join pesante)
    -- --------------------------------------------------------
    IF @rnd IN (0, 1, 2)
    BEGIN
        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        SELECT
            @i,
            'SELECT_Orders_Detail',
            COUNT(*)
        FROM SalesLT.SalesOrderHeader soh
        JOIN SalesLT.SalesOrderDetail  sod ON soh.SalesOrderID  = sod.SalesOrderID
        JOIN SalesLT.Product           p   ON sod.ProductID     = p.ProductID
        JOIN SalesLT.ProductCategory   pc  ON p.ProductCategoryID = pc.ProductCategoryID
        WHERE soh.TotalDue > 100
          AND pc.Name NOT LIKE 'Accessories%';
    END

    -- --------------------------------------------------------
    -- 2. SELECT: clienti con indirizzo (index seek su range)
    -- --------------------------------------------------------
    ELSE IF @rnd IN (3, 4)
    BEGIN
        SET @CustomerID = (ABS(CHECKSUM(NEWID())) % 847) + 1;   -- max CustomerID in AW-LT ~847

        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        SELECT
            @i,
            'SELECT_Customer_Address',
            COUNT(*)
        FROM SalesLT.Customer          c
        JOIN SalesLT.CustomerAddress   ca ON c.CustomerID  = ca.CustomerID
        JOIN SalesLT.Address           a  ON ca.AddressID  = a.AddressID
        WHERE c.CustomerID BETWEEN @CustomerID AND @CustomerID + 30;
    END

    -- --------------------------------------------------------
    -- 3. SELECT: aggregazione prezzi per categoria
    -- --------------------------------------------------------
    ELSE IF @rnd = 5
    BEGIN
        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        SELECT TOP 1
            @i,
            'SELECT_Price_Agg',
            COUNT(*)
        FROM SalesLT.Product p
        JOIN SalesLT.ProductCategory pc ON p.ProductCategoryID = pc.ProductCategoryID
        GROUP BY pc.Name
        ORDER BY AVG(p.ListPrice) DESC;
    END

    -- --------------------------------------------------------
    -- 4. SELECT: ricerca full-text simulata su nome prodotto
    -- --------------------------------------------------------
    ELSE IF @rnd = 6
    BEGIN
        DECLARE @Term NVARCHAR(20);
        SET @Term = CASE (@i % 5)
            WHEN 0 THEN N'Road'
            WHEN 1 THEN N'Mountain'
            WHEN 2 THEN N'Touring'
            WHEN 3 THEN N'Classic'
            ELSE        N'HL'
        END;

        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        SELECT
            @i,
            'SELECT_Product_Search',
            COUNT(*)
        FROM SalesLT.Product p
        JOIN SalesLT.ProductModel pm ON p.ProductModelID = pm.ProductModelID
        WHERE p.Name LIKE N'%' + @Term + N'%'
           OR pm.Name LIKE N'%' + @Term + N'%';
    END

    -- --------------------------------------------------------
    -- 5. UPDATE: aggiorna ModifiedDate su subset prodotti
    -- --------------------------------------------------------
    ELSE IF @rnd = 7 AND @EnableWrites = 1
    BEGIN
        UPDATE TOP (3) SalesLT.Product
        SET ModifiedDate = SYSDATETIME()
        WHERE ProductID % 5 = (@i % 5);

        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        VALUES (@i, 'UPDATE_Product', @@ROWCOUNT);
    END

    -- --------------------------------------------------------
    -- 6. INSERT + DELETE su tabella staging
    -- --------------------------------------------------------
    ELSE IF @rnd IN (8, 9) AND @EnableWrites = 1
    BEGIN
        IF OBJECT_ID('SalesLT.WorkloadStaging') IS NULL
        BEGIN
            CREATE TABLE SalesLT.WorkloadStaging (
                ID          INT IDENTITY PRIMARY KEY,
                BatchID     INT,
                CustomerID  INT,
                Payload     NVARCHAR(200),
                CreatedAt   DATETIME2 DEFAULT SYSDATETIME()
            );
        END

        SET @CustomerID = (ABS(CHECKSUM(NEWID())) % 847) + 1;

        INSERT INTO SalesLT.WorkloadStaging (BatchID, CustomerID, Payload)
        SELECT
            @i,
            @CustomerID,
            c.FirstName + N' ' + c.LastName + N' | ' + ISNULL(a.City, N'N/A')
        FROM SalesLT.Customer c
        LEFT JOIN SalesLT.CustomerAddress ca ON c.CustomerID = ca.CustomerID
        LEFT JOIN SalesLT.Address         a  ON ca.AddressID = a.AddressID
        WHERE c.CustomerID = @CustomerID;

        -- Pulizia rolling: mantieni solo ultimi 500
        DELETE FROM SalesLT.WorkloadStaging
        WHERE ID < (SELECT MAX(ID) - 500 FROM SalesLT.WorkloadStaging);

        INSERT INTO #WorkloadLog (IterationID, OperationType, RowsAffected)
        VALUES (@i, 'INSERT_Staging', @@ROWCOUNT);
    END

    -- --------------------------------------------------------
    -- Progress ogni 10 iterazioni
    -- --------------------------------------------------------
    IF @PrintProgress = 1 AND @i % 10 = 0
        RAISERROR('Iteration %d / %d', 0, 1, @i, @Iterations) WITH NOWAIT;

    SET @Delay = '00:00:00.' + RIGHT('000' + CAST(@DelayMs AS VARCHAR(3)), 3);
    WAITFOR DELAY @Delay;
END

-- ============================================================
-- Report finale
-- ============================================================
SELECT
    OperationType,
    COUNT(*)        AS TotalOps,
    SUM(RowsAffected) AS TotalRows,
    MIN(RecordedAt) AS FirstOp,
    MAX(RecordedAt) AS LastOp,
    DATEDIFF(MILLISECOND, MIN(RecordedAt), MAX(RecordedAt)) AS TotalMs
FROM #WorkloadLog
GROUP BY OperationType
ORDER BY TotalOps DESC;

-- Cleanup
-- DROP TABLE IF EXISTS SalesLT.WorkloadStaging;