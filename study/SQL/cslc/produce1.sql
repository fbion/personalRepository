USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[production_occupy_divde]    Script Date: 01/19/2018 17:00:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO





ALTER PROC [ODM].[production_occupy_divde]
AS 

DECLARE @dept_id VARCHAR(255)
DECLARE @iyperiod VARCHAR(50)
DECLARE @max_iyperiod VARCHAR(50)
DECLARE @driver_update_date date
DECLARE @dvd_update_date date


DECLARE @shareHardCost decimal(28,10)
DECLARE @shareSoftCost decimal(28,10)
DECLARE @deptTotalWorkingHour decimal(28,10)
DECLARE @epiWorkingHour decimal(28,10)
DECLARE @rate decimal(28,10)
DECLARE @prodSrvKey VARCHAR(50)
DECLARE @prodEleCode VARCHAR(255)
DECLARE @driven_code VARCHAR(255)
DECLARE @cur_amount decimal(28,10)
DECLARE @total_tmp decimal(28,10)
DECLARE @tailCountingAmount decimal(28,10)
DECLARE @tailTotalAmount decimal(28,10)
DECLARE @totalDeptCost decimal(28,10)
--稿费
DECLARE @writeAmount decimal(28,10)
--采购Key
DECLARE @purchageAmount decimal(28,10)
--用于检查字段
DECLARE @checkDigit int
--用于直接计入填报总数
DECLARE @totalInputValue  decimal(28,10)
--用于硬件占比总成本
DECLARE @totalHardwareCost decimal(28,10)
--用于服务到产品的二次分摊
DECLARE @product_key  VARCHAR(50)
--用于判断是否使用活动工时
DECLARE @isUseActivityHour VARCHAR(5)


--RETURN 0
--取得动因配置最新的会计区间
--以工时填报表为基准
SET @iyperiod = '2016-04'
--首先取得运维总工时
SET @deptTotalWorkingHour = 0
SELECT @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKING_VALUE,0)) AS DECIMAL(28,10))
FROM [ODM].[COST_A_DEPT_SRV_FOR_PROD_MAP_T] a
WHERE a.DEPT_CODE = '3' and a.IYPERIOD=@iyperiod and a.PRODUCT_KEY<>'0'

--首先分摊全产品共用资源 - 按照运维工时进行分摊
IF(@deptTotalWorkingHour IS NOT NULL AND @deptTotalWorkingHour <> 0)
    BEGIN
	    --分摊共用硬件
		SET @cur_amount=0
        SELECT @cur_amount=CAST(SUM(ISNULL(DBLDEPR,0)) AS DECIMAL(28,10))
        FROM ODM.FUN_GETASSETS(2, 0, '0', @iyperiod)

		IF(@cur_amount IS NOT NULL AND @cur_amount <> 0)
		    BEGIN
			    --初始化尾差计算成本
				SET @total_tmp=0
				SET @tailCountingAmount=0
		        SET @tailTotalAmount=0
				SET @rate=0
				DECLARE prod_com_ocup_cusor CURSOR FOR
		            SELECT a.PRODUCT_KEY,  ROUND(CAST(SUM(ISNULL(a.WORKING_VALUE,0)) AS DECIMAL(28,10))/@deptTotalWorkingHour,9) percentage
			        FROM [ODM].[COST_A_DEPT_SRV_FOR_PROD_MAP_T] a
				    WHERE a.DEPT_CODE='3' and a.IYPERIOD=@iyperiod and
				          a.PRODUCT_KEY <> '0'
				    GROUP BY a.PRODUCT_KEY
			    OPEN prod_com_ocup_cusor
				FETCH NEXT FROM prod_com_ocup_cusor INTO @product_key, @rate--循环处理运维工时占比
                WHILE @@FETCH_STATUS = 0
				    BEGIN
					    --进行尾差处理(处理占比除不尽的情况)
			            IF (1- @total_tmp <= @rate)
			                BEGIN
							    SET @tailCountingAmount = (@cur_amount-@tailTotalAmount)
			                END 
						ELSE 
						    BEGIN
							    SET @tailCountingAmount=round(@cur_amount*@rate,10)
						    END       
						--将部门下每个产品/服务占用成本元素的成本插入COST_A_ACTIVITY_COST 表中		    
				        INSERT INTO [ODM].COST_A_PROD_OCCUPY_ASSETS(PROD_CODE, ASSET_TYPE, SHARE_TYP, AMOUNT,IYPERIOD)
			                VALUES (@product_key
		                           ,0
			                       ,0
			                       ,ISNULL(@tailCountingAmount,0)
				                   ,@iyperiod)

						SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                    SET @total_tmp =  @total_tmp + @rate

					    FETCH NEXT FROM prod_com_ocup_cusor INTO @product_key, @rate--循环处理运维工时占比
					END
				CLOSE prod_com_ocup_cusor
				DEALLOCATE  prod_com_ocup_cusor
			END

END





