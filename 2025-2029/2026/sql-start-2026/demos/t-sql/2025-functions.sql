-------------------------------------------------------------------------------
-- PRODUCT()
-------------------------------------------------------------------------------
SELECT  finInstrument
    ,   PRODUCT(1 + rateOfReturn) OVER (PARTITION BY finInstrument) AS CompoundedReturn
FROM    (VALUES
            (0.1626,  'instrumentA')
        ,   (0.0483,  'instrumentB')
        ,   (0.2689,  'instrumentC')
        ,   (-0.1944, 'instrumentA')
        ,   (0.2423,  'instrumentA')
        ) AS MyTable(rateOfReturn, finInstrument);
GO

-------------------------------------------------------------------------------
-- BASE_64_ENCODE() and BASE64_DECODE()
-------------------------------------------------------------------------------
SELECT
    BASE64_ENCODE(0xCAFECAFE) AS non_url_safe_encoded
,   BASE64_ENCODE(0xCAFECAFE, 1) AS url_safe_encoded
GO

SELECT 
    BASE64_DECODE('yv7K/g==') AS non_url_safe_decoded
,   BASE64_DECODE('yv7K_g') AS url_safe_decoded
,   BASE64_DECODE('y v7K_g') AS url_safe_decoded_ignore_whitespaces
GO

-------------------------------------------------------------------------------
-- UNISTR()
-------------------------------------------------------------------------------
SELECT UNISTR(N'Hello! \D83D\DE00');
SELECT UNISTR(N'Hello! \+01F603');
GO

-- legacy collations not supported for non unicode data types, but still supported for unicode data types
SELECT DISTINCT p.language,
                p.codepage, c.*
FROM sys.fn_helpcollations() AS c
CROSS APPLY (VALUES (LEFT(c.name, CHARINDEX('_', c.name) - 1),
    COLLATIONPROPERTY(c.name, 'codepage'))) AS p(language, codepage)
WHERE p.codepage NOT IN (
    0 /* Unicode Only collation */,
    65001 /* UTF-8 code page */
);

-- for example the following query on varchar works
SELECT UNISTR('Hello! \D83D\DE00' COLLATE Latin1_General_100_CI_AS_KS_SC_UTF8);
GO

-- while the following query on varchar fails because of the unsupported legacy collation
SELECT UNISTR('Hello! \D83D\DE00' COLLATE SQL_Latin1_General_CP1_CI_AS);
GO

-------------------------------------------------------------------------------
-- || ANSI SQL String Concatenation Operator
-- ||= compound assignment operator for string concatenation
-------------------------------------------------------------------------------
SELECT
    CONCAT('Hello', ' ', 'World!') AS TSQLFunctionConcatenatedString
,   'Hello' + ' ' + 'World!' AS TSQLLegacyConcatenatedString
,   'Hello' || ' ' || 'World!' AS ANSIConcatenatedString;
GO

DECLARE @str VARCHAR(100) = 'Hello';
SET @str ||= ' World!';
SELECT  @str AS CompoundConcatenatedString;
GO