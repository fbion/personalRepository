USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[Pro_getcostelevalue]    Script Date: 01/19/2018 16:43:19 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER proc [ODM].[Pro_getcostelevalue]
as 
begin
/*iyear为当年，存储过程将初始化本年数据*/
declare @iyear nvarchar(10)
set @iyear=left(CONVERT(varchar(100), GETDATE(), 112),4)
/*清除表当年数据*/
delete from [ESREPORT].[ODM].[COST_CT_ANALYSIS] where left(IYPERIOD,4)=@iyear

/*获取月份*/
select distinct IYPERIOD into #iyperiod from ESREPORT.ODM.FCT_ACCASS where  left(IYPERIOD,4)=@iyear

--获得业务需求部门的当期值
SELECT finFact.CDEPT_ID, ctMapping.[CTELE_CODE],SUM(finfact.md) AS amount,finFact.IYPERIOD   INTO #busDeptCurCost
FROM [ESREPORT].[ODM].[COST_ACCTCODE_CTELE_MAP] AS ctMapping, [ESREPORT].[ODM].[FCT_ACCASS] AS finFact
WHERE  finFact.CDEPT_ID='5'
   AND left(finFact.CCODE, len(ctMapping.CCODE)) = ctMapping.CCODE
   and left(finFact.IYPERIOD,4)=@iyear
GROUP BY ctMapping.[CTELE_CODE], finFact.CDEPT_ID, finFact.IYPERIOD


/*获取当期值*/
SELECT  ctMapping.[CTELE_CODE], finFact.IYPERIOD, finFact.CDEPT_ID, 
        CASE WHEN finFact.CDEPT_ID='5' THEN 0
		     WHEN finFact.CDEPT_ID='201' THEN 
			      (SUM(ISNULL(finfact.md,0)) + ISNULL((SELECT a.amount FROM #busDeptCurCost a WHERE a.CTELE_CODE=ctMapping.CTELE_CODE and a.IYPERIOD=finFact.IYPERIOD),0))
		     ELSE SUM(finfact.md) END AS amount INTO #curvalue
FROM [ESREPORT].[ODM].[COST_ACCTCODE_CTELE_MAP] AS ctMapping, [ESREPORT].[ODM].[FCT_ACCASS] AS finFact
WHERE left(finFact.CCODE, len(ctMapping.CCODE)) = ctMapping.CCODE
      and left(finFact.IYPERIOD,4)=@iyear
GROUP BY ctMapping.[CTELE_CODE], finFact.CDEPT_ID, finFact.IYPERIOD


/*获取累计值*/
select a.CTELE_CODE,b.IYPERIOD,a.CDEPT_ID,SUM(amount) sumamount  into #sumvalue from 
#curvalue as a ,#iyperiod as b
where a.IYPERIOD <= b.IYPERIOD and
      left(a.IYPERIOD, 4)=LEFT (b.IYPERIOD,4)
group by a.CTELE_CODE,b.IYPERIOD, a.CDEPT_ID


select a.CTELE_CODE,a.CDEPT_ID,a.IYPERIOD,a.amount, b.sumamount into #pre_ana
from #curvalue as a, #sumvalue as b
where a.CDEPT_ID=b.CDEPT_ID and 
      a.CTELE_CODE=b.CTELE_CODE and
	  a.IYPERIOD=b.IYPERIOD


/*向表中插入数据-不含合并项的数据*/
INSERT INTO 
[ESREPORT].[ODM].[COST_CT_ANALYSIS] ([CT_CODE],[CDEPT_ID],[IYPERIOD],[CUR_AMOUNT],[SUM_AMOUNT])
select a.CTELE_CODE,a.CDEPT_ID,a.IYPERIOD,a.amount, a.sumamount
from #pre_ana a
where a.CDEPT_ID NOT IN (select b.SUB_DEPT_ID  from odm.COST_CT_ANA_DEPT_MAPPING b)


/*向表中插入数据-含合并项的数据*/
INSERT INTO 
[ESREPORT].[ODM].[COST_CT_ANALYSIS] ([CT_CODE],[CDEPT_ID],[IYPERIOD],[CUR_AMOUNT],[SUM_AMOUNT])
select a.CTELE_CODE, b.DISP_DEPT_ID,a.IYPERIOD, SUM(a.amount), SUM(a.sumamount)
from #pre_ana a, odm.COST_CT_ANA_DEPT_MAPPING b
where a.CDEPT_ID = b.SUB_DEPT_ID and
      a.CDEPT_ID IN (select SUB_DEPT_ID from odm.COST_CT_ANA_DEPT_MAPPING)
   GROUP BY a.CTELE_CODE, b.DISP_DEPT_ID,a.IYPERIOD


drop table #sumvalue
drop table #iyperiod
drop table #curvalue
drop table #pre_ana
drop table #busDeptCurCost


/*iyear为当年，存储过程将初始化本年数据*/
/*删除当年数据*/
--------??????????----------------
DELETE FROM [ESREPORT].ODM.COST_ALLOC_VALUE WHERE LEFT(IYPERIOD,4)=@iyear

/*获取当年下的所有月份,在求合计值时使用*/
select distinct YEARMONTH into #iyperiod1 from ESREPORT.ODM.COM_CALENDAR where left(YEARMONTH,4)=@iyear


/*获取所有月份的当期结果*/
select (CASE WHEN b.O_ACCO_CODE = '7' THEN
(SUM(a.MD)/7*2.5) ELSE SUM(a.MD) END) amount, b.O_ACCO_CODE,a.IYPERIOD into #amount
from 
[ESREPORT].[ODM].[FCT_ACCASS] as a,
[ESREPORT].[ODM].[COST_OACCO_ACCO_MAP] as b,
[ESREPORT].[ODM].[COST_OACCO_DEPART_GET_MAP] as d
where 
a.CCODE=b.CCODE
and
b.O_ACCO_CODE=d.O_ACCO_CODE
and
a.CDEPT_ID=d.CDEPT_ID
and left(a.IYPERIOD,4)=@iyear
group by
b.O_ACCO_CODE,a.IYPERIOD

/*获取所有月份累计值*/
select SUM(a.amount) sumamount,a.O_ACCO_CODE,ip.YEARMONTH into #sumamount from #amount as a 
,#iyperiod1 as ip
where 
a.IYPERIOD<=ip.YEARMONTH
and
LEFT(a.IYPERIOD,4)=LEFT(ip.YEARMONTH,4)
group by a.O_ACCO_CODE,ip.YEARMONTH


/*获取当年要存入数据库中的结果 */
/*将当年结果存入数据库表中*/
----------???????------------------------

INSERT INTO 
[ESREPORT].ODM.COST_ALLOC_VALUE (IYPERIOD,ALLOC_CODE,CUR_AMOUNT,SUM_AMOUNT)
select a.IYPERIOD,a.O_ACCO_CODE,a.amount,s.sumamount from #amount as a,
#sumamount as s
where a.IYPERIOD=s.YEARMONTH
and
a.O_ACCO_CODE=s.O_ACCO_CODE





drop table #sumamount
drop table #amount
drop table #iyperiod1

end



