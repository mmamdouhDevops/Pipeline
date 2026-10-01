-- 002 – additive change: new nullable columns (never drop/rename in a forward script)
IF COL_LENGTH(N'reporting.DailyTaskStats', N'HighPriority') IS NULL
    ALTER TABLE reporting.DailyTaskStats ADD HighPriority int NULL, LowPriority int NULL;
GO
