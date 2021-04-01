USE [¿]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[proc_name_here]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	IF (SELECT [name] FROM sys.tables WHERE [name] = 'log_table_name') IS NULL
	BEGIN
		CREATE TABLE log_table_schema.log_table_name (
			[id] INT IDENTITY(1,1) NOT NULL,
			[name] VARCHAR(255) NOT NULL,
			[run_date] DATETIME NULL,
			[alert_flag] TINYINT DEFAULT (0) NOT NULL,
			[threshold] TINYINT NOT NULL,
			[value_1] VARCHAR(255) NULL
		)
	END

    --	set flag for database status to be 'offline' aka still restoring logs
	DECLARE @status BIT = 0
	IF (SELECT 1 FROM sys.databases WHERE [name] = 'log_shipped_database' AND (state_desc <> 'ONLINE' OR user_access_desc <> 'MULTI_USER')) = 1
	BEGIN
		SET @status = 1
	END

	IF (@status = 1)
	BEGIN
		DECLARE @database_state_desc VARCHAR(50) = (SELECT state_desc FROM sys.databases WHERE [name] = 'log_shipped_database')
		DECLARE @database_user_access_desc VARCHAR(50) = (SELECT user_access_desc FROM sys.databases WHERE [name] = 'log_shipped_database')

		SELECT 'Database State: ' + @database_state_desc AS LogDate, '' AS ProcessInfo, 'Database User Access Level: ' + @database_user_access_desc AS [Text] INTO #database_states 

		--	create object(s) for reading the errorlog
		IF OBJECT_ID('tempdb..#sp_readerrorlog') IS NOT NULL 
			DROP TABLE #sp_readerrorlog
	
		CREATE TABLE #sp_readerrorlog (
			LogDate DATETIME,
			ProcessInfo VARCHAR(100),
			[Text] VARCHAR(1000)
		)

		INSERT INTO #sp_readerrorlog 
		EXEC master.dbo.xp_readerrorlog 0, 1, "Recovery of database 'log_shipped_database'", "seconds", NULL, NULL, "desc"

		--	create object(s) for fuzzy offline time 
		IF OBJECT_ID('tempdb..#offline_time') IS NOT NULL 
			DROP TABLE #offline_time
	
		CREATE TABLE #offline_time (
			LogDate DATETIME,
			ProcessInfo VARCHAR(100),
			[Text] VARCHAR(1000)
		)

		INSERT INTO #offline_time		   
		EXEC master.dbo.xp_readerrorlog 0, 1, "SINGLE_USER to ON for database 'log_shipped_database'", NULL, NULL, NULL, "desc"

		DECLARE @seconds_behind VARCHAR(100) = (
			SELECT TOP 1 
				LTRIM(RTRIM(SUBSTRING([text], CHARINDEX('approximately', [text]) + LEN('approximately'), CHARINDEX('seconds', [text]) - CHARINDEX('approximately', [text]) - LEN('approximately')))) 
				FROM #sp_readerrorlog 
				ORDER BY LogDate DESC
			)

		UPDATE log_table_schema.log_table_name
		SET 
			log_table_schema_flag = COALESCE(log_table_schema_flag,0) + 1,
			run_date = GETDATE(), 
			value_1 = 'Minute(s) behind: ' + CAST(CAST(@seconds_behind / 60 AS INT) AS VARCHAR(100))
		WHERE 
			[name] = 'log_shipped_database Log Shipping log_table_schema'

		DECLARE @alert_flag TINYINT = (SELECT alert_flag FROM log_table_schema.log_table_name WHERE [name] = 'alert_name')
		DECLARE @threshold TINYINT = (SELECT threshold FROM log_table_schema.log_table_name WHERE [name] = 'alert_name')

		DECLARE @s_subject VARCHAR(200) = (
			CASE @alert_flag 
				WHEN 1 THEN 'Latent Log Shipping on ' + @@SERVERNAME
				WHEN 2 THEN 'Priority 1 - Latent Log Shipping on ' + @@SERVERNAME
				ELSE 'Latent Log Shipping on ' + @@SERVERNAME
			END
		)

		--	declare variable(s)
		DECLARE @html NVARCHAR(MAX)
		DECLARE @s_recepients NVARCHAR(MAX)

		--	build email body
		EXEC usp_QueryToHTMLTable 
			@html = @html OUTPUT,  
			@query = N'
			SELECT LogDate, ProcessInfo, [Text] FROM  #database_states
			UNION ALL
			SELECT TOP (1) ''The TOP (5) most recent sp_readerrorlog entries for log shipping: '' AS LogDate, NULL AS ProcessInfo, ''log_shipped_database has been offline for approximately: '' + CAST(DATEDIFF(MINUTE, [LogDate], GETDATE()) as VARCHAR(10)) + '' minutes'' as [Text] FROM #offline_time
			UNION ALL
			SELECT TOP (5) CAST(LogDate AS VARCHAR(20)) AS LogDate, ProcessInfo, [Text] FROM #sp_readerrorlog
			'
		--	send email 		
		IF (@alert_flag = @threshold)
		BEGIN
			SET @s_recepients = 'email1;email2'
		END
		ELSE
		BEGIN
			SET @s_recepients = 'email1'
		END

		EXEC msdb.dbo.sp_send_dbmail
			@profile_name = 'Default',
			@recipients = @s_recepients,
			@subject = @s_subject,
			@body = @html,
			@body_format = 'HTML',
			@append_query_error = 1
	END

	IF (@status = 0)
	BEGIN
		UPDATE log_table_schema.log_table_name
		SET 
			log_table_schema_flag = 0, 
			run_date = GETDATE(),
			value_1 = NULL
		WHERE 
			[name] = 'alert_name' AND
			alert_flag <> 0
	END

END
