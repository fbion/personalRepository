USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[Pro_BG_CostBudgetDetail]    Script Date: 01/19/2018 16:56:09 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:		<Author,,Zengzy>
-- Create date: <Create Date, 2016-7-13 14:39:18>
-- Description:	<Description,, 预算按照成本粒度，按照指定的分摊因素 分摊预算 获得每个部门的成本预算金额>
-- =============================================
ALTER PROCEDURE [ODM].[Pro_BG_CostBudgetDetail]
	-- Add the parameters for the stored procedure here
	--<@Param1, sysname, @p1> <Datatype_For_Param1, , int> = <Default_Value_For_Param1, , 0>, 
	--<@Param2, sysname, @p2> <Datatype_For_Param2, , int> = <Default_Value_For_Param2, , 0>
    @BUDGETYEAR INT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- Insert statements for procedure here
	--SELECT <@Param1, sysname, @p1>, <@Param2, sysname, @p2>

    
    --创建临时表T 存储预算金额及对应成本 分摊动因相关信息
    CREATE TABLE #T
    (
         BUDGETYEAR INT ,
         DEPTNAME VARCHAR(50),
         BUDGETID VARCHAR(50) ,
         BUDGETNAME VARCHAR(200) ,
         CURRENTBALANCE DECIMAL(20,2),
         COSTNAME VARCHAR(50),
         SHAREFLAG CHAR,
         COSTID VARCHAR(50) ,
         DRIVERSID VARCHAR(50),
         DRIVERSNAME VARCHAR(100)
    );
    CREATE TABLE #T1
    (
        BUDGETYEAR INT ,
        DRIVERSID VARCHAR(50) ,
        ESDEPNAME VARCHAR(50) ,
        Proportion DECIMAL(10,8)
    );
    CREATE TABLE #BG_COSTBUDGETDETAIL
    (
	    BUDGETYEAR INT ,
	    DEPARTNAME NVARCHAR(50) ,
	    COSTID NVARCHAR(50) ,
	    COSTNAME NVARCHAR(50) ,
	    AMOUNT DECIMAL(26,8) ,
    )
    INSERT #T
    (
        BUDGETYEAR ,
        DEPTNAME ,
        BUDGETID ,
        BUDGETNAME ,
        CURRENTBALANCE ,
        COSTNAME ,
        SHAREFLAG ,
        COSTID ,
        DRIVERSID ,
        DRIVERSNAME
    )
    SELECT
        A.BUDGETYEAR ,
        A.DEPTNAME ,
        A.BUDGETID ,
        A.BUDGETNAME ,
        A.CURRENTBALANCE ,
        B.COSTNAME ,
        B.SHAREFLAG ,
        C.DIST_CODE COSTID ,
        D.DRIVERSID ,
        D.DRIVERSNAME 
    FROM ODM.FCT_BUDGET A
    LEFT JOIN ODM.BG_BudgetCostMapping B
     ON A.BUDGETYEAR = B.BUDGETYEAR
    AND A.BUDGETID = B.BUDGETID
    LEFT JOIN ODM.COST_DISTELEMENT C
     ON B.COSTNAME = C.DIST_NAME
    LEFT JOIN ODM.BG_ShareDrivers D
     ON B.BUDGETYEAR = D.BUDGETYEAR
    AND B.BUDGETID = D.BUDGETID
    AND B.DEPARTNAME = D.DEPARTNAME
    WHERE A.TYPE = 'FeiYong'     ---获取费用类预算的末级预算科目 过滤掉往来款和资产类预算科目
     AND  A.CHILDCOUNT = 0
     AND  A.DEPTH > 3
     AND  A.BUDGETYEAR = @BUDGETYEAR
     AND  LEFT(A.BUDGETID,4) NOT IN (SELECT BUDGETID FROM ODM.FCT_BUDGET WHERE BUDGETYEAR = @BUDGETYEAR AND BUDGETNAME IN ('往来款','资产') ) ;


    ----计算人数占比，将部门映射到ES系统部门粒度，计算该部门在当前分摊动因下的人数占比
    INSERT INTO #T1
    (
        BUDGETYEAR ,
        DRIVERSID ,
        ESDEPNAME ,
        Proportion
    )
    SELECT
        BUDGETYEAR ,
        DRIVERSID ,
        ESDEPNAME ,
        CAST(ISNULL(POPULATION,0) AS FLOAT) / SUM(POPULATION)OVER(PARTITION BY DRIVERSID) Proportion
    FROM
    (    
        SELECT
            A.BUDGETYEAR ,
            A.DRIVERSID ,
            B.ESDEPNAME ,
            SUM(A.POPULATION) POPULATION
        FROM ODM.BG_DriversdDetails A
        LEFT JOIN ODM.BG_ESUFDepartMap B
         ON A.DEPARTID = B.CDEPCODE 
        WHERE BUDGETYEAR = @BUDGETYEAR
        GROUP BY
            A.BUDGETYEAR ,
            A.DRIVERSID ,
            B.ESDEPNAME
    )C ;

    INSERT INTO #BG_COSTBUDGETDETAIL
    (
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME ,
        AMOUNT
    )
    --------------不需要分摊的成本项
    SELECT
       BUDGETYEAR ,
       DEPTNAME ,
       COSTID ,
       COSTNAME ,
       SUM(CURRENTBALANCE) CURRENTBALANCE
    FROM #T
    WHERE SHAREFLAG = 0
    AND COSTNAME IS NOT NULL
    GROUP BY
        BUDGETYEAR ,
        DEPTNAME ,
        COSTID ,
        COSTNAME ;

    -----按照人数占比分摊的项目
    INSERT INTO #BG_COSTBUDGETDETAIL
    (
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME ,
        AMOUNT
    )
    SELECT
        A.BUDGETYEAR ,
        B.ESDEPNAME ,
        A.COSTID ,
        A.COSTNAME ,
        A.CURRENTBALANCE * B.Proportion AMOUNT
    FROM #T A
    LEFT JOIN #T1 B
     ON A.BUDGETYEAR = B.BUDGETYEAR
    AND A.DRIVERSID = B.DRIVERSID
    WHERE SHAREFLAG = 1
    AND A.DRIVERSID IN ('01','02','03','04');


    ----计算按照部门成本占比分摊的科目


    --先将当年手工维护的数据放在临时表中
    
    INSERT INTO #BG_COSTBUDGETDETAIL
    (
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME ,
        AMOUNT
    )
    SELECT
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME ,
        AMOUNT
    FROM ODM.BG_CostBudgetDetailHandWork
    WHERE BUDGETYEAR = @BUDGETYEAR ;
    
    DECLARE @Row INT
    DECLARE @Count INT
    SET @Row = ISNULL((SELECT COUNT(1) FROM #T WHERE DRIVERSID = '07'),0)
    SET @Count = 1
    
    WHILE @Count <= @Row 
    BEGIN
        WITH T2 AS
        (    
            SELECT
                DISTINCT
                BUDGETYEAR ,
                DEPARTNAME ,
                CAST(SUM(AMOUNT)OVER(PARTITION BY DEPARTNAME) AS FLOAT) /SUM(AMOUNT)OVER(PARTITION BY BUDGETYEAR) Proportion
            FROM #BG_COSTBUDGETDETAIL
            WHERE BUDGETYEAR = @BUDGETYEAR
        )

        INSERT #BG_COSTBUDGETDETAIL
        (
            BUDGETYEAR ,
            DEPARTNAME ,
            COSTID ,
            COSTNAME ,
            AMOUNT
        )
        SELECT
            A.BUDGETYEAR ,
            B.DEPARTNAME ,
            A.COSTID ,
            A.COSTNAME ,
            A.CURRENTBALANCE * B.Proportion 
        FROM
        (
            SELECT
                BUDGETYEAR ,
                DEPTNAME ,
                BUDGETID ,
                BUDGETNAME ,
                CURRENTBALANCE ,
                COSTID ,
                COSTNAME ,
                ROW_NUMBER()OVER(ORDER BY CURRENTBALANCE DESC) Num
            FROM #T
            WHERE DRIVERSID = '07'
        )A
        LEFT JOIN T2 B
        ON A.BUDGETYEAR = B.BUDGETYEAR
        WHERE A.Num = @Count

        SET @Count = @Count+1
    END

    DELETE FROM ODM.BG_COSTBUDGETDETAIL WHERE BUDGETYEAR = @BUDGETYEAR ;

    SELECT
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME ,
        SUM(AMOUNT) AMOUNT
    FROM #BG_COSTBUDGETDETAIL
    GROUP BY
        BUDGETYEAR ,
        DEPARTNAME ,
        COSTID ,
        COSTNAME 
    ORDER BY
        DEPARTNAME ,
        COSTID ;

    ---删除临时表 
    --DROP TABLE #BG_COSTBUDGETDETAIL;
    --DROP TABLE #T;
    --DROP TABLE #T1;

END


