USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[Pro_CostDataInitialization]    Script Date: 01/19/2018 17:00:26 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROC [ODM].[Pro_CostDataInitialization]
AS 


DECLARE @cur_period int
DECLARE @record_count int
DECLARE @cur_update_date date
DECLARE @next_update_date date
DECLARE @next_period int
DECLARE @previous_period int
DECLARE @before_pre_period int
--取得当月的会计期间
 SELECT @cur_period=CASE WHEN LEN(DATEPART(MONTH, GETDATE())) = 1
                         THEN CAST(CAST(DATEPART(YEAR, GETDATE()) AS nvarchar) + '0' + CAST(DATEPART(MONTH, GETDATE()) AS nvarchar) AS int)
                         ELSE CAST(CAST(DATEPART(YEAR, GETDATE()) AS nvarchar)+ CAST(DATEPART(MONTH, GETDATE()) AS nvarchar) AS int)
		            END

/*
/*初始化配置数据时使用*/
set @cur_period=201607    
*/
--取得下月会计期间
IF (RIGHT(@cur_period,2) = '12')
    BEGIN
	   SET @next_period = (CAST(LEFT(@cur_period, 4) AS int) + 1)*100 + 1
	END
ELSE
    BEGIN
	    SET @next_period = @cur_period + 1
	END


--取得上月会计期间
IF (RIGHT(@cur_period,2) = '01')
    BEGIN
	    SET @previous_period = (CAST(LEFT(@cur_period, 4) AS int) - 1)*100 + 12
	END
ELSE
    BEGIN
	    SET @previous_period = @cur_period - 1
	END


--取得上上月会计期间
IF (RIGHT(@previous_period,2) = '01')
    BEGIN
	    SET @before_pre_period = (CAST(LEFT(@previous_period, 4) AS int) - 1)*100 + 12
	END
ELSE
    BEGIN
	    SET @before_pre_period = @previous_period - 1
	END
		

--部门全成本数据初始化工作----START
--a. 处理公共费用部门分摊预处理数据-ODM.COST_OACCO_DEPART_POST_MAP
--判断是否存在上一个月的数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_OACCO_DEPART_POST_MAP
where IYPERIOD=@previous_period

--如果上个月没有数据那需要使用上上个月的数据初始化上个月数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_OACCO_DEPART_POST_MAP(O_ACCO_CODE, CDEPT_ID, IYPERIOD)
		    SELECT O_ACCO_CODE, CDEPT_ID, @previous_period
			FROM ODM.COST_OACCO_DEPART_POST_MAP
			WHERE IYPERIOD=@before_pre_period
	END
--部门全成本数据初始化工作----END


--产品全成本数据初始化工作---START
--删除表中NULL值空值数据
DELETE FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T
WHERE  WORKTIME_VALUE IS NULL

DELETE FROM ODM.COST_A_DEPT_ELE_MAP_T
WHERE  DRIVER_VALUE IS NULL

DELETE FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T
WHERE WORKING_VALUE IS NULL

DELETE FROM ODM.COST_A_SRV_PROD_DRIVER_MAP_T
WHERE WORKING_VALUE IS NULL

DELETE FROM ODM.COST_PRODUCT_RESOURCE_MAP
WHERE CUR_AMOUNT IS NULL

--初始化固定资产底稿
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_FIXEDASSETS_USE_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上个月没有数据那需要导入上上月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_FIXEDASSETS_USE_MAP(ASSET_OCCUPY_CODE,ASSET_OCCUPY_PURPOSE,FLEX_OCCUPY_CODE1,FLEX_OCCUPY_CODE2,FLEX_OCCUPY_CODE3
		                                         ,IS_VIRTUAL_RES,OCCUPY_PERCENTAGE1,OCCUPY_PERCENTAGE2,OCCUPY_PERCENTAGE3,SASSETNUM, IYPERIOD)
		    SELECT a.ASSET_OCCUPY_CODE, a.ASSET_OCCUPY_PURPOSE, a.FLEX_OCCUPY_CODE1, a.FLEX_OCCUPY_CODE2
			      ,a.FLEX_OCCUPY_CODE3, a.IS_VIRTUAL_RES,a.OCCUPY_PERCENTAGE1, a.OCCUPY_PERCENTAGE2, a.OCCUPY_PERCENTAGE3
				  ,a.SASSETNUM, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_FIXEDASSETS_USE_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END

--初始化二次分摊服务分摊到产品上面的映射
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_A_SERVICE_FOR_PRODUCT_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前个月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_A_SERVICE_FOR_PRODUCT_MAP(DEPT_CODE,SERVICE_KEY,PRODUCT_KEY,IYPERIOD)
		    SELECT a.DEPT_CODE, a.SERVICE_KEY, a.PRODUCT_KEY, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_A_SERVICE_FOR_PRODUCT_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END

--初始化部门与成本元素动因映射表
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_A_DEPT_ELE_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_A_DEPT_ELE_MAP(DEPT_CODE,ELE_CODE,DRIVER_CODE,FLAG_ISBEUSEDFORADD,IYPERIOD)
		    SELECT a.DEPT_CODE, a.ELE_CODE, a.DRIVER_CODE, a.FLAG_ISBEUSEDFORADD, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_A_DEPT_ELE_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END


--初始化部门组别映射关系
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_GROUP_DEPT_MAP a
where REPLACE(a.YEARANDMONTH,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_GROUP_DEPT_MAP(CDEPT_CODE,GROUP_CODE,YEARANDMONTH)
		    SELECT a.CDEPT_CODE, a.GROUP_CODE,(LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_GROUP_DEPT_MAP a
			WHERE REPLACE(YEARANDMONTH,'-','')=(@before_pre_period)
	END


--初始化部门与产品服务映射关系
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_A_DEPT_PROORSER_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_A_DEPT_PROORSER_MAP(DEPT_CODE,PROORSER_CODE,PROORSER_TYPE,IYPERIOD)
		    SELECT a.DEPT_CODE, a.PROORSER_CODE, a.PROORSER_TYPE, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_A_DEPT_PROORSER_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END


--初始化部门和活动映射关系表
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_A_DEPT_ACTIVITY_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_A_DEPT_ACTIVITY_MAP(DEPT_CODE,ACTIVITY_CODE,IYPERIOD)
		    SELECT a.DEPT_CODE, a.ACTIVITY_CODE, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_A_DEPT_ACTIVITY_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END



--初始化3-4产品服务活动映射关系表
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_PRO_SER_THIRD_FOURTH_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_PRO_SER_THIRD_FOURTH_MAP(THIRD_CODE,FOURTH_CODE,PERCENTAGE,IYPERIOD)
		    SELECT a.THIRD_CODE, a.FOURTH_CODE, a.PERCENTAGE, (LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_PRO_SER_THIRD_FOURTH_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END


--初始化2-3产品服务活动映射关系表
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_PRO_SER_SECOND_THIRD_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_PRO_SER_SECOND_THIRD_MAP(SECOND_CODE,THIRD_CODE,IYPERIOD)
		    SELECT a.SECOND_CODE, a.THIRD_CODE,(LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_PRO_SER_SECOND_THIRD_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END


--初始化1-2产品服务活动映射关系表
--判断是否存在上月数据
SELECT @record_count=COUNT(*)
FROM ODM.COST_PRO_SER_FIRST_SECOND_MAP a
where REPLACE(a.IYPERIOD,'-','')=@previous_period

--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
	    INSERT INTO ODM.COST_PRO_SER_FIRST_SECOND_MAP(FIRST_CODE,SECOND_CODE,IYPERIOD)
		    SELECT a.FIRST_CODE, a.SECOND_CODE,(LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2))
			FROM ODM.COST_PRO_SER_FIRST_SECOND_MAP a
			WHERE REPLACE(IYPERIOD,'-','')=(@before_pre_period)
	END
  
	SELECT @record_count=COUNT(*)
FROM ODM.COST_A_PRO_CT_ELEMENT a
where REPLACE(a.IYPERIOD,'-','')=@previous_period
--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
    BEGIN
      INSERT INTO ODM.COST_A_PRO_CT_ELEMENT(PRD_ELE_CODE,PRD_ELE_NAME,IYPERIOD,PARENT_CODE,order_id)
      SELECT a.PRD_ELE_CODE, a.PRD_ELE_NAME,(LEFT(@previous_period,4) + '-' + RIGHT(@previous_period,2)),a.PARENT_CODE,a.order_id
      FROM ODM.COST_A_PRO_CT_ELEMENT a
      WHERE REPLACE(a.IYPERIOD,'-','')=(@before_pre_period)
 END
	
--初始化资源填报的数据

SELECT @record_count = COUNT(*)
FROM ODM.COST_PRODUCT_RESOURCE_MAP a
WHERE REPLACE(a.IYPERIOD, '-', '') = @previous_period
--如果上月没有数据那需要导入前月的数据
IF (@record_count = 0)
BEGIN
	INSERT INTO ODM.COST_PRODUCT_RESOURCE_MAP (
		RESOURCE_ID
		,PROD_SRV_KEY
		,DEPT_ID
		,IYPERIOD
		,YEAR_DEPRECITION
		,RESOURCE_NUMBER
		,CARRY_VALUE
		,CUR_AMOUNT
		,RESOURCE_TYPE
		,RESOURCE_NAME
		)
	SELECT RESOURCE_ID
		,PROD_SRV_KEY
		,DEPT_ID
		,(LEFT(@previous_period, 4) + '-' + RIGHT(@previous_period, 2))
		,YEAR_DEPRECITION
		,RESOURCE_NUMBER
		,CARRY_VALUE
		,CUR_AMOUNT
		,RESOURCE_TYPE
		,RESOURCE_NAME
	FROM ODM.COST_PRODUCT_RESOURCE_MAP a
	WHERE REPLACE(a.IYPERIOD, '-', '') = (@before_pre_period)
END	
	
--产品全成本数据初始化工作---END



