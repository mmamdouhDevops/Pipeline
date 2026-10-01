-- 001 – reporting schema (idempotent: safe to re-run)
IF SCHEMA_ID(N'reporting') IS NULL EXEC(N'CREATE SCHEMA reporting');
GO
IF OBJECT_ID(N'reporting.DailyTaskStats', N'U') IS NULL
BEGIN
    CREATE TABLE reporting.DailyTaskStats (
        StatDate      date          NOT NULL CONSTRAINT PK_DailyTaskStats PRIMARY KEY,
        Created       int           NOT NULL CONSTRAINT DF_DailyTaskStats_Created DEFAULT 0,
        Completed     int           NOT NULL CONSTRAINT DF_DailyTaskStats_Completed DEFAULT 0,
        Overdue       int           NOT NULL CONSTRAINT DF_DailyTaskStats_Overdue DEFAULT 0,
        RefreshedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_DailyTaskStats_Refreshed DEFAULT SYSUTCDATETIME()
    );
END
GO
