-------------------------------------------------------------------------------
-- sample data for fuzzy string match
-------------------------------------------------------------------------------
USE master;
GO
DROP DATABASE IF EXISTS Strings;
GO
CREATE DATABASE Strings;
GO
USE Strings;
GO
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO
-- Step 1: Create the table
DROP TABLE IF EXISTS WordPairs;
CREATE TABLE WordPairs
(
    WordID INT IDENTITY (1, 1) PRIMARY KEY, -- Auto-incrementing ID
    WordUK NVARCHAR (50), -- UK English word
    WordUS NVARCHAR (50)  -- US English word
);

-- Step 2: Insert the data
INSERT INTO WordPairs (WordUK, WordUS)
VALUES ('Colour', 'Color'),
       ('Flavour', 'Flavor'),
       ('Centre', 'Center'),
       ('Theatre', 'Theater'),
       ('Organise', 'Organize'),
       ('Analyse', 'Analyze'),
       ('Catalogue', 'Catalog'),
       ('Programme', 'Program'),
       ('Metre', 'Meter'),
       ('Honour', 'Honor'),
       ('Neighbour', 'Neighbor'),
       ('Travelling', 'Traveling'),
       ('Grey', 'Gray'),
       ('Defence', 'Defense'),
       ('Practise', 'Practice'), -- Verb form in UK
       ('Practice', 'Practice'), -- Noun form in both
       ('Aluminium', 'Aluminum'),
       ('Cheque', 'Check'); -- Bank cheque vs. check
GO
-------------------------------------------------------------------------------
-- EDIT_DISTANCE()
-- this function calculates the Levenshtein distance between two strings,
-- which is the number of edits (insertions, deletions, substitutions) required
-- to transform one string into another.
-------------------------------------------------------------------------------
SELECT WordUK,
       WordUS,
       EDIT_DISTANCE(WordUK, WordUS) AS Distance
FROM WordPairs
WHERE EDIT_DISTANCE(WordUK, WordUS) <= 2
ORDER BY Distance ASC;
GO

-------------------------------------------------------------------------------
-- Example EDIT_DISTANCE_SIMILARITY()
-- this function calculates the similarity score between two strings based on
-- the Levenshtein distance, returning a value between 0 and 100, where 100
-- indicates identical strings and 0 indicates completely different strings.
-------------------------------------------------------------------------------
SELECT WordUK,
       WordUS,
       EDIT_DISTANCE_SIMILARITY(WordUK, WordUS) AS Similarity
FROM WordPairs
WHERE EDIT_DISTANCE_SIMILARITY(WordUK, WordUS) >= 75
ORDER BY Similarity DESC;
GO

-------------------------------------------------------------------------------
-- Example JARO_WINKLER_DISTANCE()
-- this function calculates the Jaro-Winkler distance between two strings,
-- which is a measure of similarity that gives more weight to the beginning of
-- the strings and is particularly effective for short strings and
-- typographical errors.
-------------------------------------------------------------------------------
SELECT WordUK,
       WordUS,
       JARO_WINKLER_DISTANCE(WordUK, WordUS) AS Distance
FROM WordPairs
WHERE JARO_WINKLER_DISTANCE(WordUK, WordUS) <= .05
ORDER BY Distance ASC;
GO

-------------------------------------------------------------------------------
-- Example JARO_WINKLER_SIMILARITY()
-- this function calculates the Jaro-Winkler similarity score between two
-- strings, returning a value between 0 and 100, where 100 indicates identical
-- strings and 0 indicates completely different strings.
-------------------------------------------------------------------------------
SELECT WordUK,
       WordUS,
       JARO_WINKLER_SIMILARITY(WordUK, WordUS) AS Similarity
FROM WordPairs
WHERE JARO_WINKLER_SIMILARITY(WordUK, WordUS) > 90
ORDER BY Similarity DESC;
GO


-------------------------------------------------------------------------------
-- All in one query
-------------------------------------------------------------------------------
SELECT T.source_string,
       T.target_string,
       EDIT_DISTANCE(T.source_string, T.target_string) AS ED_Distance,
       JARO_WINKLER_DISTANCE(T.source_string, T.target_string) AS JW_Distance,
       EDIT_DISTANCE_SIMILARITY(T.source_string, T.target_string) AS ED_Similarity,
       JARO_WINKLER_SIMILARITY(T.source_string, T.target_string) AS JW_Similarity
FROM (VALUES ('Black', 'Red'),
             ('Colour', 'Yellow'),
             ('Colour', 'Color'),
             ('Microsoft', 'Msft'),
             ('Regex', 'Regex')
     ) AS T(source_string, target_string);
GO