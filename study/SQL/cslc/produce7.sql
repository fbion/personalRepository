USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[Pro_BG_BUDGETEXECUTIONES]    Script Date: 01/19/2018 17:00:20 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
ALTER PROCEDURE [ODM].[Pro_BG_BUDGETEXECUTIONES]
	-- Add the parameters for the stored procedure here
	--<@Param1, sysname, @p1> <Datatype_For_Param1, , int> = <Default_Value_For_Param1, , 0>, 
	--<@Param2, sysname, @p2> <Datatype_For_Param2, , int> = <Default_Value_For_Param2, , 0>
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- Insert statements for procedure here
	--SELECT <@Param1, sysname, @p1>, <@Param2, sysname, @p2>
    
    --创建临时表T 存储 预算执行金额
    CREATE TABLE #T
    (
        BUDGETYEAR           INT            ,
        STATISTICMONTH       INT            ,
        SHOWBUDGETID         NVARCHAR(20)   ,
        SHOWBUDGETNAME       NVARCHAR(100)  ,
        BUDGETBEGIN          DECIMAL(20,2)  ,
        CHANGEDAMOUNTBEF     DECIMAL(20,2)  ,
        ADJUSTBEF            DECIMAL(20,2)  ,
        MIDYEARCHANGE        DECIMAL(20,2)  ,
        MIDADJUST            DECIMAL(20,2)  ,
        CHANGEDAMOUNTAFT     DECIMAL(20,2)  ,
        ADJUSTAFT            DECIMAL(20,2)  ,
        CURRENTBALANCE       DECIMAL(20,2)  ,
        FINISHINVOICE        DECIMAL(20,2)  ,
        FINISHINVOICEAGG     DECIMAL(20,2)  
    );
    DECLARE @StatisticYear VARCHAR(4) 
    SET @StatisticYear = CONVERT(VARCHAR(4),CURRENT_TIMESTAMP-1,112)

    ------获取年中调整的时间节点
    DECLARE @MidYearTime DATETIME
    DECLARE @temp DATETIME
    SELECT @temp = CAST(VALUE AS DATETIME)
    FROM STG.SYS_SYSTEMVARIABLES
    WHERE BELONGYEAR = YEAR(CURRENT_TIMESTAMP-1)
     AND  PART = '预算编制' 
     AND  NAME = '年中调整时间节点'
    SET @MidYearTime = ISNULL(@temp,CURRENT_TIMESTAMP)
    ;

    --------获取年初金额初始化的时间节点
    DECLARE @Initialization DATETIME
    DECLARE @temp1 DATETIME
    SELECT @temp1 = CAST(VALUE AS DATETIME)
    FROM STG.SYS_SYSTEMVARIABLES
    WHERE BELONGYEAR = YEAR(CURRENT_TIMESTAMP-1)
     AND  PART = '预算编制' 
     AND  NAME = '年初金额初始化时间节点'
    SET @Initialization = ISNULL(@temp1,YEAR(CURRENT_TIMESTAMP-1)+'0101')
    ;


    WITH T1 AS
    (
        SELECT
            A.BUDGETYEAR ,
            A.BUDGETID ,
            A.CURRENTBALANCE ,    --预算控制金额
            A.INITBALANCE BudgetBegin,       --年初预算
            ISNULL(D.CHANGEDAMOUNTBef,0) CHANGEDAMOUNTBef, --年中调整前调剂金额
            CASE WHEN A.CHILDCOUNT = 0 THEN ISNULL(E.CHANGEDAMOUNT,0) ELSE 0 END MidYearChange , --年中调整金额
            ISNULL(D.CHANGEDAMOUNTAft,0) CHANGEDAMOUNTAft  --年中调整后调剂金额
        FROM ODM.FCT_BUDGET A     --预算信息表
        LEFT JOIN 
        (                         ----获得预算调整的数据
            SELECT
                B.BUDGETYEAR ,
                B.BUDGETID ,
                SUM(CASE
                       WHEN B.APPLYTYPE = 1 AND C.FLOWFINISHTIME <= @MidYearTime THEN -B.CHANGEDAMOUNT
                       WHEN B.APPLYTYPE = 0 AND C.FLOWFINISHTIME <= @MidYearTime THEN  B.CHANGEDAMOUNT
                       ELSE 0
                    END) CHANGEDAMOUNTBef ,   --1为减少 0为增加  年中调整时间点之前的数据
                SUM(CASE
                       WHEN B.APPLYTYPE = 1 AND C.FLOWFINISHTIME >  @MidYearTime THEN -B.CHANGEDAMOUNT 
                       WHEN B.APPLYTYPE = 0 AND C.FLOWFINISHTIME >  @MidYearTime THEN  B.CHANGEDAMOUNT 
                       ELSE 0
                    END) CHANGEDAMOUNTAft     --1为减少 0为增加  年中调整时间点之后的数据
            FROM ODM.FCT_BUDGETADJUST B     --预算调剂申请单表
            LEFT JOIN (SELECT UUID,STATUS,FLOWFINISHTIME FROM ODM.FCT_FORMDATA WHERE BILLTYPE = 366 ) C   --单据信息表
             ON B.FK_FORMID = C.UUID
            WHERE B.BUDGETYEAR = @StatisticYear
             AND  C.STATUS = 3                                ----单据状态为3的时候是已确认的单据，流程中的预算调剂不展示
             AND  B.APPLYDATE >= @Initialization              ----年初金额导入之前的调剂，不参与后续的计算
            GROUP BY B.BUDGETYEAR ,B.BUDGETID
        ) D
         ON A.BUDGETID = D.BUDGETID
        AND A.BUDGETYEAR = D.BUDGETYEAR
        LEFT JOIN
        (
          SELECT
              BUDGETYEAR ,
              BUDGETID ,
              SUM(CHANGEDAMOUNT) CHANGEDAMOUNT
          FROM ODM.FCT_BUDGETDATACHANGE               --预算变化情况表，包含预算执行情况和预算的变化情况
          WHERE CHANGETYPE = 2                        --状态为2的数据为差异导入的数据
           AND  BUDGETYEAR = @StatisticYear
           AND  CHANGEDATE >= CAST(@MidYearTime AS DATE)
           AND  CHANGEDATE <  DATEADD(DAY,1,CAST(@MidYearTime AS DATE))
          GROUP BY
              BUDGETYEAR ,
              BUDGETID
        ) E
         ON A.BUDGETID = E.BUDGETID
        AND A.BUDGETYEAR = E.BUDGETYEAR
        WHERE A.BUDGETYEAR = @StatisticYear
    ),

    ----------获取预算的数据，同时构建预算每月的结构
    T2 AS
    (
        SELECT
            A.BUDGETYEAR ,
            C.YEARMONTH StatisticMonth ,
            A.SHOWBUDGETID ,
            A.SHOWBUDGETNAME ,
            CASE WHEN C.MONTH = 1 THEN ISNULL(B.BudgetBegin,0.0) ELSE 0.0 END BudgetBegin ,
            CASE WHEN C.MONTH = 1 THEN ISNULL(B.CHANGEDAMOUNTBef,0.0) ELSE 0.0 END CHANGEDAMOUNTBef ,
            CASE WHEN C.MONTH = 1 THEN ISNULL(B.MidYearChange,0.0) ELSE 0.0 END MidYearChange ,
            CASE WHEN C.MONTH = 1 THEN ISNULL(B.CHANGEDAMOUNTAft,0.0) ELSE 0.0 END CHANGEDAMOUNTAft ,
            CASE WHEN C.MONTH = 1 THEN ISNULL(B.CURRENTBALANCE,0.0) ELSE 0.0 END CURRENTBALANCE
        FROM ODM.BG_SHOWBUDGETESMAP A
        LEFT JOIN T1 B
         ON A.BUDGETID = B.BUDGETID
        AND A.BUDGETYEAR = B.BUDGETYEAR
        CROSS JOIN (SELECT YEARMONTH ,MONTH FROM ODM.COM_CALENDAR WHERE YEAR = @StatisticYear AND DAY = 1 AND YEARMONTH <= CONVERT(VARCHAR(6),CURRENT_TIMESTAMP,112)) C
        WHERE A.BUDGETYEAR = @StatisticYear
         AND  LEFT(A.SHOWBUDGETID,2) = (SELECT SHOWBUDGETID FROM ODM.BG_SHOWBUDGETESMAP WHERE BUDGETYEAR = @StatisticYear AND SHOWBUDGETNAME = '支出' )
    ),

    ---获得预算的每月执行数
    T3 AS
    (
        SELECT
            C.BUDGETYEAR ,
            C.BUDGETID ,
            C.StatisticMonth ,
            ISNULL(D.FINISHINVOICE,0.0) FINISHINVOICE
        FROM 
        (
            SELECT
                A.BUDGETYEAR ,
                A.BUDGETID ,
                B.YEARMONTH StatisticMonth
            FROM ODM.FCT_BUDGET A
            CROSS JOIN 
            (
                SELECT YEARMONTH ,MONTH FROM ODM.COM_CALENDAR 
                WHERE YEAR = @StatisticYear AND DAY = 1 
                AND YEARMONTH <= CONVERT(VARCHAR(6),CURRENT_TIMESTAMP,112)
            ) B
            WHERE A.BUDGETYEAR = @StatisticYear
        )C
        LEFT JOIN 
        (
            SELECT
                BUDGETYEAR,
                BUDGETID,
                CONVERT(VARCHAR(6),OPERATIONDATE,112) StatisticMonth ,
                SUM(FINISHINVOICE) FINISHINVOICE
            FROM ODM.FCT_BUDGETDATACHANGE
            WHERE BUDGETYEAR = @StatisticYear
             AND  BUDGETID IS NOT NULL
            GROUP BY
                CONVERT(VARCHAR(6), OPERATIONDATE, 112) ,
                BUDGETYEAR ,
                BUDGETID
        )D
        ON C.BUDGETYEAR = D.BUDGETYEAR
        AND C.BUDGETID = D.BUDGETID
        AND C.StatisticMonth = D.StatisticMonth
    ),

    ---获得预算执行的年初到当月的累计值
    T4 AS
    (
        SELECT
            A.BUDGETYEAR ,
            A.BUDGETID ,
            A.StatisticMonth ,
            AVG(A.FINISHINVOICE) FINISHINVOICE ,
            SUM(B.FINISHINVOICE) FINISHINVOICEAGG
        FROM T3 A
        LEFT JOIN T3 B
         ON A.BUDGETID = B.BUDGETID
        AND A.BUDGETYEAR = B.BUDGETYEAR
        AND A.StatisticMonth >= B.StatisticMonth
        GROUP BY
            A.BUDGETYEAR ,
            A.BUDGETID ,
            A.StatisticMonth
    )
    INSERT INTO #T
    (
        BUDGETYEAR ,
        STATISTICMONTH ,
        SHOWBUDGETID ,
        SHOWBUDGETNAME ,
        BUDGETBEGIN ,
        CHANGEDAMOUNTBEF ,
        ADJUSTBEF ,
        MIDYEARCHANGE ,
        MIDADJUST ,
        CHANGEDAMOUNTAFT ,
        ADJUSTAFT ,
        CURRENTBALANCE ,
        FINISHINVOICE ,
        FINISHINVOICEAGG
    )
    SELECT
        A.BUDGETYEAR ,
        A.StatisticMonth ,
        A.SHOWBUDGETID ,
        '' SHOWBUDGETNAME ,
        A.BudgetBegin ,
        A.CHANGEDAMOUNTBef ,
        A.BudgetBegin + A.CHANGEDAMOUNTBef AdjustBef ,
        A.MidYearChange ,
        A.BudgetBegin + A.CHANGEDAMOUNTBef + A.MidYearChange MidAdjust,
        A.CHANGEDAMOUNTAft ,
        A.BudgetBegin + A.CHANGEDAMOUNTBef + A.MidYearChange + A.CHANGEDAMOUNTAft AdjustAft,
        A.CURRENTBALANCE ,
        ISNULL(D.FINISHINVOICE,0.0) FINISHINVOICE ,
        ISNULL(D.FINISHINVOICEAGG,0.0) FINISHINVOICEAGG
    FROM T2 A
    LEFT JOIN
    (
        SELECT
            C.BUDGETYEAR ,
            B.StatisticMonth ,
            C.SHOWBUDGETID ,
            C.SHOWBUDGETNAME ,
            B.FINISHINVOICE ,
            B.FINISHINVOICEAGG 
        FROM T4 B
        LEFT JOIN ODM.BG_SHOWBUDGETESMAP C
         ON B.BUDGETID = C.BUDGETID
        AND B.BUDGETYEAR = C.BUDGETYEAR
        WHERE C.ID IS NOT NULL
    ) D
     ON A.BUDGETYEAR = D.BUDGETYEAR
    AND A.SHOWBUDGETID = D.SHOWBUDGETID
    AND A.StatisticMonth = D.StatisticMonth
    
     ;


    ---获取收入部分的预算和实际值
    WITH T5 AS
    (
        SELECT
            C.BUDGETYEAR ,
            C.SHOWBUDGETID ,
            C.STATISTICMONTH ,
            C.MONTH ,
            ISNULL(D.AMOUNT,0) FinishInvoice
        FROM 
        (
            SELECT
                A.BUDGETYEAR ,
                A.SHOWBUDGETID ,
                B.YEARMONTH STATISTICMONTH,
                B.MONTH
            FROM 
            ( ----获取收入部分的展示预算代码
                SELECT
                    BUDGETYEAR ,SHOWBUDGETID 
                FROM ODM.BG_SHOWBUDGETESMAP
                WHERE LEFT(SHOWBUDGETID,2) = (SELECT SHOWBUDGETID FROM ODM.BG_SHOWBUDGETESMAP WHERE BUDGETYEAR = @StatisticYear AND SHOWBUDGETNAME = '收入')
                 AND  BUDGETYEAR = @StatisticYear
            ) A
            CROSS JOIN
            (  --获得收入代码所有月份的结构
                SELECT YEARMONTH ,MONTH 
                FROM ODM.COM_CALENDAR
                WHERE YEAR = @StatisticYear AND DAY = 1
                 AND  YEARMONTH <= CONVERT(VARCHAR(6),CURRENT_TIMESTAMP,112)
            ) B
        )C
        LEFT JOIN
        (    --关联收入的每月实际数，有数据的显示数据，当月没有发生则为0
            SELECT
                YEAR(STATISTICMONTH) BudgetYear ,
                CONVERT(VARCHAR(6),STATISTICMONTH,112) STATISTICMONTH ,
                SHOWBUDGETID ,
                AMOUNT
            FROM ODM.BG_REVENUEBUDGETACTUAL
            WHERE FLAG = 1
             AND  LEFT(SHOWBUDGETID,2) = (SELECT SHOWBUDGETID FROM ODM.BG_SHOWBUDGETESMAP WHERE BUDGETYEAR = @StatisticYear AND SHOWBUDGETNAME = '收入')
             AND  YEAR(STATISTICMONTH) = @StatisticYear
        )D
         ON C.BUDGETYEAR = D.BudgetYear
        AND C.SHOWBUDGETID = D.SHOWBUDGETID
        AND C.STATISTICMONTH = D.STATISTICMONTH
    )
    INSERT INTO #T
    (
        BUDGETYEAR ,
        STATISTICMONTH ,
        SHOWBUDGETID ,
        SHOWBUDGETNAME ,
        BUDGETBEGIN ,
        CHANGEDAMOUNTBEF ,
        ADJUSTBEF ,
        MIDYEARCHANGE ,
        MIDADJUST ,
        CHANGEDAMOUNTAFT ,
        ADJUSTAFT ,
        CURRENTBALANCE ,
        FINISHINVOICE ,
        FINISHINVOICEAGG
    )
    SELECT
        C.BUDGETYEAR ,
        C.STATISTICMONTH ,
        C.SHOWBUDGETID ,
        '' SHOWBUDGETNAME ,
        CAST(0 AS DECIMAL(20,2)) BudgetBegin ,
        CAST(0 AS DECIMAL(20,2)) CHANGEDAMOUNTBef ,
        CAST(0 AS DECIMAL(20,2)) AdjustBef ,
        CAST(0 AS DECIMAL(20,2)) MidYearChange ,
        CAST(0 AS DECIMAL(20,2)) MidAdjust ,
        CAST(0 AS DECIMAL(20,2)) CHANGEDAMOUNTAft ,
        CASE WHEN C.MONTH = 1 THEN ISNULL(D.CurrentBalance,0) ELSE 0 END AdjustAft ,
        CASE WHEN C.MONTH = 1 THEN ISNULL(D.CurrentBalance,0) ELSE 0 END CurrentBalance ,  --预算值
        C.FinishInvoice ,                                                        --当月值
        C.FinishInvoiceAgg                                                       --当月到年初的累计值
    FROM 
    (  ------利用不等式链接，获取当月金额和截止到当月的本年累计金额
        SELECT
            A.BUDGETYEAR ,
            A.STATISTICMONTH ,
            A.SHOWBUDGETID ,
            A.MONTH ,
            AVG(A.FinishInvoice) FinishInvoice,
            SUM(B.FinishInvoice) FinishInvoiceAgg
        FROM T5 A
        LEFT JOIN T5 B
         ON A.BUDGETYEAR = B.BUDGETYEAR
        AND A.SHOWBUDGETID = B.SHOWBUDGETID
        AND A.STATISTICMONTH >= B.STATISTICMONTH
        GROUP BY
            A.BUDGETYEAR ,
            A.SHOWBUDGETID ,
            A.STATISTICMONTH ,
            A.MONTH
    )C
    LEFT JOIN
    ( ------------FLAG为0 时为预算数据 获取当年的预算数据
        SELECT
            YEAR(STATISTICMONTH) BudgetYear ,
            SHOWBUDGETID ,
            AMOUNT CurrentBalance
        FROM ODM.BG_REVENUEBUDGETACTUAL
        WHERE FLAG = 0
         AND  STATISTICMONTH = (SELECT MAX(STATISTICMONTH) FROM ODM.BG_REVENUEBUDGETACTUAL WHERE FLAG = 0 AND  YEAR(STATISTICMONTH) = @StatisticYear)
    )D
     ON C.BudgetYear = D.BudgetYear
    AND C.SHOWBUDGETID = D.SHOWBUDGETID  ;



    -----由收入与支出，获取净利润的相关数据
    INSERT INTO #T
    ( 
        BUDGETYEAR ,
        STATISTICMONTH ,
        SHOWBUDGETID ,
        SHOWBUDGETNAME ,
        BUDGETBEGIN ,
        CHANGEDAMOUNTBEF ,
        ADJUSTBEF ,
        MIDYEARCHANGE ,
        MIDADJUST ,
        CHANGEDAMOUNTAFT ,
        ADJUSTAFT ,
        CURRENTBALANCE ,
        FINISHINVOICE ,
        FINISHINVOICEAGG
    )
    SELECT
        A.BUDGETYEAR ,
        A.STATISTICMONTH ,
        '04' SHOWBUDGETID,
        '' SHOWBUDGETNAME ,
        A.BUDGETBEGIN  - B.BUDGETBEGIN ,
        A.CHANGEDAMOUNTBEF - B.CHANGEDAMOUNTBEF ,
        A.ADJUSTBEF - B.ADJUSTBEF ,
        A.MIDYEARCHANGE - B.MIDYEARCHANGE ,
        A.MIDADJUST - B.MIDADJUST ,
        A.CHANGEDAMOUNTAFT - B.CHANGEDAMOUNTAFT ,
        A.ADJUSTAFT - B.ADJUSTAFT ,
        A.CURRENTBALANCE - B.CURRENTBALANCE ,
        A.FINISHINVOICE - B.FINISHINVOICE ,
        A.FINISHINVOICEAGG - B.FINISHINVOICEAGG
    FROM
    (
        SELECT
            BUDGETYEAR ,
            STATISTICMONTH ,
            LEFT(SHOWBUDGETID,2) SHOWBUDGETID ,
            SUM(BUDGETBEGIN) BUDGETBEGIN,
            SUM(CHANGEDAMOUNTBEF) CHANGEDAMOUNTBEF,
            SUM(ADJUSTBEF) ADJUSTBEF,
            SUM(MIDYEARCHANGE) MIDYEARCHANGE,
            SUM(MIDADJUST) MIDADJUST,
            SUM(CHANGEDAMOUNTAFT) CHANGEDAMOUNTAFT,
            SUM(ADJUSTAFT) ADJUSTAFT,
            SUM(CURRENTBALANCE) CURRENTBALANCE,
            SUM(FINISHINVOICE) FINISHINVOICE,
            SUM(FINISHINVOICEAGG) FINISHINVOICEAGG
        FROM #T
        WHERE LEFT(SHOWBUDGETID,2) = '01'
        GROUP BY
            BUDGETYEAR ,
            STATISTICMONTH ,
            LEFT(SHOWBUDGETID,2)
    ) A
    LEFT JOIN
    (
        SELECT
            BUDGETYEAR ,
            STATISTICMONTH ,
            LEFT(SHOWBUDGETID,2) SHOWBUDGETID ,
            SUM(BUDGETBEGIN) BUDGETBEGIN,
            SUM(CHANGEDAMOUNTBEF) CHANGEDAMOUNTBEF,
            SUM(ADJUSTBEF) ADJUSTBEF,
            SUM(MIDYEARCHANGE) MIDYEARCHANGE,
            SUM(MIDADJUST) MIDADJUST,
            SUM(CHANGEDAMOUNTAFT) CHANGEDAMOUNTAFT,
            SUM(ADJUSTAFT) ADJUSTAFT,
            SUM(CURRENTBALANCE) CURRENTBALANCE,
            SUM(FINISHINVOICE) FINISHINVOICE,
            SUM(FINISHINVOICEAGG) FINISHINVOICEAGG
        FROM #T
        WHERE LEFT(SHOWBUDGETID,2) = '02'
        GROUP BY
            BUDGETYEAR ,
            STATISTICMONTH ,
            LEFT(SHOWBUDGETID,2)
    ) B
    ON A.BUDGETYEAR = B.BUDGETYEAR
    AND A.STATISTICMONTH = B.STATISTICMONTH ;


    ---获取投资收益部分的预算和实际值
    WITH T6 AS
    (
        SELECT
            C.BUDGETYEAR ,
            C.SHOWBUDGETID ,
            C.STATISTICMONTH ,
            C.MONTH ,
            ISNULL(D.AMOUNT,0) FinishInvoice
        FROM 
        (
            SELECT
                A.BUDGETYEAR ,
                A.SHOWBUDGETID ,
                B.YEARMONTH STATISTICMONTH,
                B.MONTH
            FROM 
            ( ----获取投资收益部分的展示预算代码
                SELECT
                    BUDGETYEAR ,SHOWBUDGETID 
                FROM ODM.BG_SHOWBUDGETESMAP
                WHERE SHOWBUDGETID = (SELECT SHOWBUDGETID FROM ODM.BG_SHOWBUDGETESMAP WHERE BUDGETYEAR = @StatisticYear AND SHOWBUDGETNAME = '投资收益')
                 AND  BUDGETYEAR = @StatisticYear
            ) A
            CROSS JOIN
            (  --获得投资收益代码所有月份的结构
                SELECT YEARMONTH ,MONTH 
                FROM ODM.COM_CALENDAR
                WHERE YEAR = @StatisticYear AND DAY = 1
                AND YEARMONTH <= CONVERT(VARCHAR(6),CURRENT_TIMESTAMP,112)
            ) B
        )C
        LEFT JOIN
        (    --关联收入的每月实际数，有数据的显示数据，当月没有发生则为0
            SELECT
                YEAR(STATISTICMONTH) BudgetYear ,
                CONVERT(VARCHAR(6),STATISTICMONTH,112) STATISTICMONTH ,
                SHOWBUDGETID ,
                AMOUNT
            FROM ODM.BG_REVENUEBUDGETACTUAL
            WHERE FLAG = 1
             AND  YEAR(STATISTICMONTH) = @StatisticYear
        )D
         ON C.BUDGETYEAR = D.BudgetYear
        AND C.SHOWBUDGETID = D.SHOWBUDGETID
        AND C.STATISTICMONTH = D.STATISTICMONTH
    )

    INSERT INTO #T
    ( 
        BUDGETYEAR ,
        STATISTICMONTH ,
        SHOWBUDGETID ,
        SHOWBUDGETNAME ,
        BUDGETBEGIN ,
        CHANGEDAMOUNTBEF ,
        ADJUSTBEF ,
        MIDYEARCHANGE ,
        MIDADJUST ,
        CHANGEDAMOUNTAFT ,
        ADJUSTAFT ,
        CURRENTBALANCE ,
        FINISHINVOICE ,
        FINISHINVOICEAGG
    )

    SELECT
        C.BUDGETYEAR ,
        C.STATISTICMONTH ,
        C.SHOWBUDGETID ,
        '' SHOWBUDGETNAME ,
        CAST(0 AS DECIMAL(20,2)) BudgetBegin ,
        CAST(0 AS DECIMAL(20,2)) CHANGEDAMOUNTBef ,
        CAST(0 AS DECIMAL(20,2)) AdjustBef ,
        CAST(0 AS DECIMAL(20,2)) MidYearChange ,
        CAST(0 AS DECIMAL(20,2)) MidAdjust ,
        CAST(0 AS DECIMAL(20,2)) CHANGEDAMOUNTAft ,
        CASE WHEN C.MONTH = 1 THEN ISNULL(D.CurrentBalance,0) ELSE 0 END AdjustAft ,
        CASE WHEN C.MONTH = 1 THEN ISNULL(D.CurrentBalance,0) ELSE 0 END CurrentBalance ,  --预算值
        C.FinishInvoice ,                                                        --当月值
        C.FinishInvoiceAgg                                                       --当月到年初的累计值
    FROM 
    (  ------利用不等式链接，获取当月金额和截止到当月的本年累计金额
        SELECT
            A.BUDGETYEAR ,
            A.STATISTICMONTH ,
            A.SHOWBUDGETID ,
            A.MONTH ,
            AVG(A.FinishInvoice) FinishInvoice,
            SUM(B.FinishInvoice) FinishInvoiceAgg
        FROM T6 A
        LEFT JOIN T6 B
         ON A.BUDGETYEAR = B.BUDGETYEAR
        AND A.SHOWBUDGETID = B.SHOWBUDGETID
        AND A.STATISTICMONTH >= B.STATISTICMONTH
        GROUP BY
            A.BUDGETYEAR ,
            A.SHOWBUDGETID ,
            A.STATISTICMONTH ,
            A.MONTH
    )C
    LEFT JOIN
    ( ------------FLAG为0 时为预算数据 获取当年的预算数据
        SELECT
            YEAR(STATISTICMONTH) BudgetYear ,
            SHOWBUDGETID ,
            AMOUNT CurrentBalance
        FROM ODM.BG_REVENUEBUDGETACTUAL
        WHERE FLAG = 0
         AND  STATISTICMONTH = (SELECT MAX(STATISTICMONTH) FROM ODM.BG_REVENUEBUDGETACTUAL WHERE FLAG = 0 AND  YEAR(STATISTICMONTH) = @StatisticYear)
    )D
     ON C.BudgetYear = D.BudgetYear
    AND C.SHOWBUDGETID = D.SHOWBUDGETID


    --删除数据
    DELETE FROM ODM.BG_BUDGETEXECUTIONES WHERE BUDGETYEAR = YEAR(CURRENT_TIMESTAMP-1) ;

    INSERT INTO ODM.BG_BUDGETEXECUTIONES
    ( 
        BUDGETYEAR ,
        STATISTICMONTH ,
        SHOWBUDGETID ,
        SHOWBUDGETNAME ,
        BUDGETBEGIN ,
        CHANGEDAMOUNTBEF ,
        ADJUSTBEF ,
        MIDYEARCHANGE ,
        MIDADJUST ,
        CHANGEDAMOUNTAFT ,
        ADJUSTAFT ,
        CURRENTBALANCE ,
        FINISHINVOICE ,
        FINISHINVOICEAGG
    )
    SELECT
        A.BUDGETYEAR ,
        A.STATISTICMONTH ,
        A.SHOWBUDGETID ,
        B.SHOWBUDGETNAME ,
        A.BUDGETBEGIN ,
        A.CHANGEDAMOUNTBEF ,
        A.ADJUSTBEF ,
        A.MIDYEARCHANGE ,
        A.MIDADJUST ,
        A.CHANGEDAMOUNTAFT ,
        A.ADJUSTAFT ,
        A.CURRENTBALANCE ,
        A.FINISHINVOICE ,
        A.FINISHINVOICEAGG
    FROM #T A
    LEFT JOIN ODM.BG_SHOWBUDGETESMAP B
    ON A.BUDGETYEAR = B.BUDGETYEAR
    AND A.SHOWBUDGETID = B.SHOWBUDGETID ;


    DROP TABLE #T ;

END
