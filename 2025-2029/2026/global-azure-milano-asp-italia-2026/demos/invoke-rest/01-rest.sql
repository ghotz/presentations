use tempdb
go

/*
    Query the Open Trivia fee API
*/

--declare @rv int;
--declare @response nvarchar(max);

--exec @rv = sp_invoke_external_rest_endpoint 
--    @method = 'GET',
--    @url = 'https://opentdb.com/api.php?amount=10',
--    @response = @response output;

--select @response;

--select * from openjson(@response);

--select * from openjson(@response, '$.result.results')
--with (
--    [type] nvarchar(50),
--    [difficulty] nvarchar(50),
--    [category] nvarchar(150),
--    [question] nvarchar(max),
--    [correct_answer] nvarchar(max),
--    [incorrect_answers] nvarchar(max) as json
--);
--go

DECLARE @rv   INT;
DECLARE @response NVARCHAR(MAX);

EXEC @rv = sp_invoke_external_rest_endpoint
    @method   = 'GET',
    @url      = 'https://the-trivia-api.com/v2/questions?limit=10',
    @response = @response OUTPUT;

-- raw response envelope
SELECT @rv AS return_code, @response AS raw_response;

-- la risposta API è un array diretto → $.result è l'array
SELECT *
FROM OPENJSON(@response, '$.result')
WITH (
    id              NVARCHAR(50),
    category        NVARCHAR(150),
    difficulty      NVARCHAR(50),
    question_text   NVARCHAR(MAX)  '$.question.text', 
    correct_answer  NVARCHAR(MAX)  '$.correctAnswer',
    incorrect_answers NVARCHAR(MAX)'$.incorrectAnswers' AS JSON
);
GO

--DECLARE @rv   INT;
--DECLARE @response NVARCHAR(MAX);

--EXEC @rv = sp_invoke_external_rest_endpoint
--    @method   = 'GET',
--    @url      = 'https://jsonplaceholder.typicode.com/posts',
--    @response = @response OUTPUT;

--SELECT *
--FROM OPENJSON(@response, '$.result')
--WITH (
--    userId INT,
--    id     INT,
--    title  NVARCHAR(200),
--    body   NVARCHAR(MAX)
--);

/*
    User mock REST API that allows POST too
*/

-- GET an existing element
declare @rv int;
declare @response nvarchar(max);

exec @rv = sp_invoke_external_rest_endpoint 
    @method = 'GET',
    @url = 'https://jsonplaceholder.typicode.com/posts/1',
    @response = @response output;

select @response;
go

-- POST a new element 
declare @rv int;
declare @response nvarchar(max);

declare @payload json = '{"title": "foo", "body": "bar", "userId": "42"}'

exec @rv = sp_invoke_external_rest_endpoint 
    @method = 'POST',
    @url = 'https://jsonplaceholder.typicode.com/posts',
    @response = @response output;

select @response;
go

/*
    REST + JSON are great together!
*/
declare @rv int;
declare @response nvarchar(max);

exec @rv = sp_invoke_external_rest_endpoint 
    @method = 'GET',
    @url = 'https://raw.githubusercontent.com/dataplat/dbatools/refs/heads/development/bin/dbatools-buildref-index.json',
    @response = @response output;

select * from openjson(@response);

with cte_sql_versions as
(
select 
    t1.[Version],
    t1.ServicePack,
    t1.SupportedUntil,
    case 
        when KBList is not null then json_array(KBList) 
        else cast(KBList_Array as json)
    end as KB
from 
    openjson(@response, '$.result.Data') with 
    (
        [Version] varchar(100),
        [ServicePack] varchar(100) '$.SP',
        [SupportedUntil] datetime2,
        [KBList] varchar(100),
        [KBList_Array] nvarchar(max) '$.KBList' as json
    ) t1 
)
select
    *
from
    cte_sql_versions
where
    ServicePack = 'RTM'

