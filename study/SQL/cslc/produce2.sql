USE [ESREPORT]
GO
/****** Object:  StoredProcedure [ODM].[Pro_PrcCostDivide]    Script Date: 01/19/2018 17:00:35 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



ALTER PROC [ODM].[Pro_PrcCostDivide]
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
DECLARE @projectHardAmount decimal(28,10)
DECLARE @projectSoftAmount decimal(28,10)

--RETURN 0
--取得动因配置最新的会计区间
--以工时填报表为基准
SELECT @max_iyperiod=MAX(a.IYPERIOD)  
FROM  [ODM].[COST_A_ACTIORGRO_PROORSER_MAP_T] a  --工时填报映射表

/*初始化数据时使用
 set @max_iyperiod='2016-10'
*/
IF (@max_iyperiod IS NULL)
    BEGIN
	     SELECT @max_iyperiod=CASE WHEN LEN(DATEPART(MONTH, GETDATE())) = 1
                         THEN CAST(DATEPART(YEAR, GETDATE()) AS nvarchar) + '0' + CAST(DATEPART(MONTH, GETDATE()) AS nvarchar)
                         ELSE CAST(DATEPART(YEAR, GETDATE()) AS nvarchar)+ CAST(DATEPART(MONTH, GETDATE()) AS nvarchar)
		            END
	END

IF (@max_iyperiod IS NOT NULL)
    BEGIN
	    --取得动因配置最后的更新时
        SELECT @driver_update_date=MAX(dateList.LATEST_DATE)
		FROM (
		       SELECT MAX(UPDATEDATE) LATEST_DATE
			   FROM [ODM].COST_A_ACTIORGRO_PROORSER_MAP_T --工时填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATE_DATE) LATEST_DATE
			   FROM [ODM].COST_A_DEPT_SRV_FOR_PROD_MAP_T a --服务产品工时填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATEDATE) LATEST_DATE
			   FROM [ODM].[COST_A_DEPT_ELE_MAP_T] --直接计入成本元素填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATE_DATE) LATEST_DATE
			   FROM [ODM].COST_A_SRV_PROD_DRIVER_MAP_T --服务产品直接计入成本元素填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATEDATE) LATEST_DATE
			   FROM [ODM].[COST_A_DEPT_HARD_SOFT_MAP] --软硬件填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATE_DATE) LATEST_DATE
			   FROM [ODM].[COST_FIXEDASSETS_USE_MAP] --固定资产/虚拟资产卡片填报
			   WHERE IYPERIOD=@max_iyperiod
			   UNION
			   SELECT MAX(UPDATE_DATE) LATEST_DATE
			   FROM [ODM].[COST_PRODUCT_RESOURCE_MAP] --资源库填报
			   WHERE IYPERIOD=@max_iyperiod
		     ) dateList


        --取得产品全成本分摊开始时间
        SELECT @dvd_update_date=MIN(a.UPDATE_DATE)
        FROM ODM.COST_A_PROD_DIV_LEVELONE a
        WHERE a.IYPERIOD = @max_iyperiod

		--判断是否需要执行成本分摊
        IF(@dvd_update_date IS NOT NULL) --如果@dvd_update_date为NULL, 说明当期还没有进行成本分摊,可以直接进行分摊，如果不为NLL,那要分情况
            BEGIN
	            IF (@driver_update_date < @dvd_update_date)  --如果分摊开始时间比动因更新时间晚，说明已经进行了分摊，并且分摊之后动因数据没有更新，可以直接返回
		            BEGIN
			            RETURN 405
			        END
	            ELSE --当期成本分摊之后，动因数据发生改变，需要重新分摊
		            BEGIN
					    --删除产品全成本一次分摊项
			            DELETE FROM ODM.COST_A_PROD_DIV_LEVELONE
						WHERE IYPERIOD = @max_iyperiod
						--删除二次全成本分摊项
						DELETE FROM ODM.COST_A_PROD_DIV_LEVELTWO
						WHERE IYPERIOD = @max_iyperiod
						--删除活动成本分摊项
						DELETE FROM ODM.COST_A_ACTIVITY_COST
						WHERE IYPERIOD = @max_iyperiod
						--删除产品分摊管理成本表
						DELETE FROM ODM.COST_A_PROD_MANAGE_COST_DIV
						WHERE IYPERIOD = @max_iyperiod
						--删除产品分摊数据
						DELETE FROM [ODM].[COST_A_PROD_OCCUPY_ASSETS]
						WHERE IYPERIOD = @max_iyperiod
			        END
	        END
	END
ELSE 
    BEGIN
	    RETURN 404
	END 
/*
--开始进行分摊
SET @max_iyperiod='2016-11'  --手动修改用于测试
--RETURN 500
*/

--以部门为维度进行一次分摊 -START
DECLARE proc_dept_curcor CURSOR FOR
    --首先分摊除管理部门的部门成本 -- 管理部门后面单独分摊
	SELECT DISTINCT a.DEPT_CODE, a.IYPERIOD
	FROM [ODM].[COST_A_DEPT_ELE_MAP] a  --从部门与成本元素的映射表中取得需要分摊的部门
	WHERE a.DEPT_CODE NOT IN ('1') AND a.IYPERIOD = @max_iyperiod  
    --WHERE a.DEPT_CODE='106' AND a.IYPERIOD = '2016-04'
--打开游标准备循环处理各部门产品/服务分摊
OPEN proc_dept_curcor 
    FETCH NEXT FROM proc_dept_curcor INTO @dept_id, @iyperiod --循环处理各个部门
	WHILE @@FETCH_STATUS = 0
	    BEGIN
		    IF (@iyperiod IS NULL OR @iyperiod='')
			    BEGIN
				    SET @iyperiod = @max_iyperiod
				END
		    --初始化部门产品服务总成本，用于后面计算基于成本占比的成本元素
		    SET @totalDeptCost = 0
			SET @deptTotalWorkingHour=0
			SET @epiWorkingHour=0
			SET @writeAmount=0
			SET @purchageAmount=0
			SET @isUseActivityHour = '1'
			SET @shareHardCost = 0
			SET @shareSoftCost = 0
			
		    --取得技术运用中心下面部门占用硬件资产共用成本：共用硬件=填报+部门占用技术运行中心硬件资源
			IF (@dept_id='3')  --如果是技术运行中心，那么直接确定技术运行中心使用的共用硬件
			    BEGIN
				   print('start to process 3')
				    --取得技术运用中心下面部门占用硬件资产共用成本
				    SELECT @shareHardCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
			        FROM ODM.FUN_GETASSETS(1, 0, '0', @iyperiod) assets --根据函数取得部门占用技术运行中心的硬件资产

					--取得技术运用中心下面部门占用共用软件成本： 共用软件=填报+部门占用技术运行中心软件资源
                    SELECT @shareSoftCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
			        FROM ODM.FUN_GETASSETS(1, 1, '0', @iyperiod) assets --根据函数取得固定资产信息


					--取得项目硬件成本
					/****** Script for SelectTopNRows command from SSMS  ******/
                    SELECT @projectHardAmount=SUM(ISNULL(a.CUR_AMOUNT,0))
                    FROM [ESREPORT].[ODM].[COST_DEPT_FULL_COSTING] a
                    WHERE CDEPT_ID in (select b.SOURCE_DEPT_CODE 
					                   from  ESREPORT.ODM.COST_A_PROD_INNER_DEPT_MAPPING b
					                   where b.PRODCOST_DEPT_CODE = '3' and b.SOURCE_DEPT_CODE like '7%') 
                      and IYPERIOD = REPLACE(@iyperiod, '-','') and a.CT_CODE='12'

					--取得项目软件成本
					/****** Script for SelectTopNRows command from SSMS  ******/
                    SELECT @projectSoftAmount=SUM(ISNULL(a.CUR_AMOUNT,0))
                    FROM [ESREPORT].[ODM].[COST_DEPT_FULL_COSTING] a
                    WHERE CDEPT_ID in (select b.SOURCE_DEPT_CODE 
					                   from  ESREPORT.ODM.COST_A_PROD_INNER_DEPT_MAPPING b
					                   where b.PRODCOST_DEPT_CODE = '3' and b.SOURCE_DEPT_CODE like '7%') 
                      and IYPERIOD = REPLACE(@iyperiod, '-','') and a.CT_CODE='13'

					IF (@shareHardCost IS NULL)
			            BEGIN
				            SET @shareHardCost = 0
				        END

         			IF (@shareSoftCost IS NULL)
			            BEGIN
				            SET @shareSoftCost = 0
				    END  


					IF (@projectHardAmount IS NULL)
			            BEGIN
				            SET @projectHardAmount = 0
				        END

         			IF (@projectSoftAmount IS NULL)
			            BEGIN
				            SET @projectSoftAmount = 0
				    END  

					SET @shareHardCost = @shareHardCost + @projectHardAmount
					SET @shareSoftCost = @shareSoftCost + @projectSoftAmount

					print ('shareCost=' + CAST(@shareSoftCost AS VARCHAR))
				END
			ELSE  --对应除技术运行中心之外的部门，需要取部门占用技术运行中心的硬件
			    BEGIN
				    --取得技术运用中心下面部门占用硬件资产共用成本
			        SELECT @shareHardCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
			        FROM ODM.FUN_GETASSETS(3, 0, @dept_id, @iyperiod) assets --根据函数取得部门占用技术运行中心的硬件资产

					--取得技术运用中心下面部门占用共用软件成本： 共用软件=填报+部门占用技术运行中心软件资源
                    SELECT @shareSoftCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
			        FROM ODM.FUN_GETASSETS(3, 1, @dept_id, @iyperiod) assets --根据函数取得固定资产信息
				END



			IF (@shareHardCost IS NULL)
			    BEGIN
				    SET @shareHardCost = 0
				END

			IF (@shareSoftCost IS NULL)
			    BEGIN
				    SET @shareSoftCost = 0
				END

			--取得该部门下在填报的总工时： 用于计算按照工时占比的成本元素
			IF (@dept_id = '204' OR @dept_id='3') --如果是测试部或者技术运行中心，工时应该是从服务对产品的映射工时取得
			    BEGIN
				    SET @deptTotalWorkingHour=0
				    SELECT  @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKING_VALUE,0)) AS DECIMAL(28,10))
					FROM  ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a  --COST_A_DEPT_SRV_FOR_PROD_MAP_T是服务对对产品的工时填报表
					 --PRODUCT_KEY=0表示服务下的产品工时总和，如果服务没有对应产品，那么就是服务本身的工时
					WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.PRODUCT_KEY='0'
				END
			ELSE --对于除技术运行中心和测试部门的总工时，就按照活动对服务/产品/活动的对应关系取得
			    BEGIN
				    --首先检查是否存在活动对服务/产品的工时填报，如果有，就用活动工时总和
					SET @checkDigit=0
			        SELECT @checkDigit=COUNT(1)
			        FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a --COST_A_ACTIORGRO_PROORSER_MAP_T是活动/工作组工时填报表
			        WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod  and a.ACTIVITYORGROUP_TYPE='1'--ACTIVITYORGROUP_TYPE为'1'表示活动工时
					--WHERE a.DEPT_CODE='108' and a.IYPERIOD='2016-04' and a.ACTIVITYORGROUP_TYPE='1'
			            
			        --如果活动工时存在，就用活动总工时
			        IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
			            BEGIN
						    SET @isUseActivityHour = '1'  --ACTIVITYORGROUP_TYPE为1表示取得是活动工时
				        END
			        ELSE --如果活动工时不存在，则使用工作组总工时，工作组工时多数时候用于对活动工时的校验
			   	        BEGIN
						    SET @isUseActivityHour = '2'  --ACTIVITYORGROUP_TYPE为2表示取得是工作组工时
				        END

					--取得总工时
					SET @deptTotalWorkingHour=0
					SELECT @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))
			        FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
			        WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and 
					      a.ACTIVITYORGROUP_TYPE=@isUseActivityHour and a.PROD_SRV_KEY <> '0'
			        GROUP BY a.DEPT_CODE
				END 
 
			--如果没有取到总工时信息，那就初始化为0，防止SQL语句执行错误
			IF (@deptTotalWorkingHour IS NULL)
			    BEGIN
				    SET @deptTotalWorkingHour=0
				END
			
			--对于存在自己资源库的部门，非共用硬件/软件是直接分摊到部门里面特定的产品或者服务上面的，
			--不需要按照工时，成本占比等动因进行分摊，所以可以直接插入一次分摊表：[COST_A_PROD_DIV_LEVELONE]
			IF (@dept_id = '3')  --技术运行中心的资源库和需要与其他自有资源库部门分开处理，因为取数方式不同
			    BEGIN
				    --检查是否存在技术运行中心使用的非共用硬件
					SET @checkDigit=0
				    SELECT @checkDigit=COUNT(1)
					FROM ODM.FUN_GETASSETS(1, 0, 'all', @iyperiod) assetList
					--ASSET_OCCUPY_CODE等于0表示共用硬件，不等于0是非共用硬件，值应该是使用硬件资产的产品/服务CODE
					WHERE assetList.ASSET_OCCUPY_CODE <> '0' 
					--插入技术运行中心的非共用硬件资源
				    IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
					   BEGIN
					       --直接将非共用硬件资源插入到一次分摊表中，1002010102表示‘非共用硬件’成本元素
					       INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELONE](DEPT_CODE, PRD_ELE_CODE, PRD_SRV_KEY, IYPERIOD,CUR_AMOUNT)
		                        SELECT @dept_id DEPT_CODE, '1002010102' ELE_CODE, a.ASSET_OCCUPY_CODE, @iyperiod, ROUND(CAST(SUM(ISNULL(a.DBLDEPR,0)) AS DECIMAL(28,10))/10000,9) RES_AMOUNT	 
	                            FROM ODM.FUN_GETASSETS(1, 0, 'all', @iyperiod) a
								WHERE a.ASSET_OCCUPY_CODE <> '0'
						        GROUP BY a.ASSET_OCCUPY_CODE
					   END

					--检查是否存在技术运行中心使用的非共用软件
					SET @checkDigit=0
				    SELECT @checkDigit=COUNT(1)
					FROM ODM.FUN_GETASSETS(1, 1, 'all', @iyperiod) assetList
					--ASSET_OCCUPY_CODE等于0表示共用软件，不等于0是非共用软件，值应该是使用软件资产的产品/服务CODE
					WHERE assetList.ASSET_OCCUPY_CODE <> '0' --只需要取得非共用硬件资源
					--插入技术运行中心的非共用软件资源，1002010202表示'非共用软件'成本元素
				    IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
					   BEGIN
					       INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELONE](DEPT_CODE, PRD_ELE_CODE, PRD_SRV_KEY, IYPERIOD,CUR_AMOUNT)
		                        SELECT @dept_id DEPT_CODE, '1002010202' ELE_CODE, a.ASSET_OCCUPY_CODE, @iyperiod, ROUND(CAST(SUM(ISNULL(a.DBLDEPR,0)) AS DECIMAL(28,10))/10000,9) RES_AMOUNT	 
	                            FROM ODM.FUN_GETASSETS(1, 1, 'all', @iyperiod) a
								WHERE a.ASSET_OCCUPY_CODE <> '0'
						        GROUP BY a.ASSET_OCCUPY_CODE
					   END
				END
			ELSE  --除去技术运行中心，检查其部门是否存在自己的资源库
			    BEGIN
				    --判断是否存在自己的硬件资源库 - 只处理非共用硬件，共用硬件通过填报可以获得
					SET @checkDigit=0
			        SELECT @checkDigit=COUNT(1)
		            FROM  [ODM].[COST_PRODUCT_RESOURCE_MAP] a   --各部门的资源库信息，保存在[COST_PRODUCT_RESOURCE_MAP]表中
	                WHERE a.IYPERIOD=@iyperiod and a.DEPT_ID=@dept_id and a.RESOURCE_TYPE=0 -- RESOURCE_TYPE=0表示取得是硬件资源

			        IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
			            BEGIN
			                --插入非共用硬件资源
	                        INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELONE](DEPT_CODE, PRD_ELE_CODE, PRD_SRV_KEY, IYPERIOD,CUR_AMOUNT)
		                        SELECT a.DEPT_ID, '1002010102' ELE_CODE, a.PROD_SRV_KEY, a.IYPERIOD, ROUND(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/10000,9) RES_AMOUNT	 
	                            FROM [ODM].[COST_PRODUCT_RESOURCE_MAP] a
	                            WHERE a.DEPT_ID=@dept_id AND a.IYPERIOD=@iyperiod and a.RESOURCE_TYPE=0 AND
						              a.PROD_SRV_KEY <> '0'  --只需要取得非共用硬件, PROD_SRV_KEY=0指的是共用硬件
						        GROUP BY a.DEPT_ID, a.IYPERIOD, a.PROD_SRV_KEY
				        END

		            --检查非共用软件资源
					SET @checkDigit=0
		            SELECT @checkDigit=COUNT(1)
		            FROM  [ODM].[COST_PRODUCT_RESOURCE_MAP] a
	                WHERE a.IYPERIOD=@iyperiod and a.DEPT_ID=@dept_id and a.RESOURCE_TYPE=1 --RESOURCE_TYPE=1表示取得软件
			
			        IF(@checkDigit IS NOT NULL AND 0 < @checkDigit)
				        BEGIN
				            --插入非共用软件资源
				            INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELONE](DEPT_CODE, PRD_ELE_CODE, PRD_SRV_KEY, IYPERIOD,CUR_AMOUNT)
		                        SELECT a.DEPT_ID, '1002010202' ELE_CODE, a.PROD_SRV_KEY, a.IYPERIOD, ROUND(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/10000,9) RES_AMOUNT	 
	                            FROM [ODM].[COST_PRODUCT_RESOURCE_MAP] a
	                            WHERE a.DEPT_ID=@dept_id AND a.IYPERIOD=@iyperiod and a.RESOURCE_TYPE=1
						          AND a.PROD_SRV_KEY <> '0' --只需要取得非共用软件, PROD_SRV_KEY=0指的是共用软件
						        GROUP BY a.DEPT_ID, a.IYPERIOD, a.PROD_SRV_KEY
				        END
				END 

			--初始化稿费与采购KEY成本
			SET @writeAmount=0
			SET @purchageAmount=0
            --开始按照部门下的各个成本元素将成本分摊到各个服务/产品之上
			DECLARE prod_tbEles_cursor CURSOR FOR
			---技术运行中心的维费及直接计入维保费需要特殊处理
           select elevalue.DEPT_CODE,elevalue.element_code,elevalue.driven_code,
                  case when element_code='100101020201' and @dept_id=3 
                        then (select sum(a.DRIVER_VALUE) value from ESREPORT.ODM.COST_A_DEPT_ELE_MAP_T as a where a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.ELE_CODE='100101020201') 
                       when element_code='1001010202' and @dept_id=3 
                        then elevalue.current_amount-(select sum(a.DRIVER_VALUE) value from ESREPORT.ODM.COST_A_DEPT_ELE_MAP_T as a where a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.ELE_CODE='100101020201') 
                       else elevalue.current_amount end current_amount
            from (		
			    SELECT eleMapping.DEPT_CODE,eleMapping.PROD_ELE_CODE element_code, eleMapping.DRIVER_CODE driven_code, CAST(SUM(ISNULL(dptCost.cur_amount,0)) AS DECIMAL(28,10)) current_amount
			    FROM ( SELECT b.DEPT_CODE DEPT_CODE, b.SOURCE_DEPT_CODE, b.DRIVER_CODE, b.ELE_CODE PROD_ELE_CODE, b.IYPERIOD, a.CT_CODE DEPT_ELE_CODE
                       FROM   --产品成本元素与部门成本元素的映射表
                            ( SELECT prcEleDepMap.DEPT_CODE, deptMap.SOURCE_DEPT_CODE, prcEleDepMap.ELE_CODE,prcEleDepMap.DRIVER_CODE,prcEleDepMap.IYPERIOD
                              FROM   [ODM].[COST_A_DEPT_ELE_MAP] prcEleDepMap,
							         [ODM].[COST_A_PROD_INNER_DEPT_MAPPING] deptMap
							         --该表用于产品全成本的组合部门向各个基础部门映射，如研发中心是由研发一部研发二部以及研发管理部组成
                              WHERE  prcEleDepMap.DEPT_CODE = deptMap.PRODCOST_DEPT_CODE 
                                   AND prcEleDepMap.DEPT_CODE =@dept_id
		                           AND prcEleDepMap.IYPERIOD = @iyperiod
								   --成本元素：硬件，软件，共用硬件/软件，非共用硬件/软件无需从部门全成本取值，所以在这里排除
		                           AND prcEleDepMap.ELE_CODE NOT IN ('10020101','10020102','1002010102', '1002010201', '1002010101', '1002010202')
	                         ) b LEFT JOIN [ODM].[COST_A_PROELE_CTELE_MAP] a ON (a.PRO_ELE_CODE = b.ELE_CODE) 
					   --与部门全成本视图左连接，因为产品成本元素有可能在部门成本视图中没有数据
			         ) eleMapping LEFT JOIN [ODM].[COM_COST_ELE_DETAILS] dptCost ON (eleMapping.DEPT_ELE_CODE = dptCost.code AND eleMapping.SOURCE_DEPT_CODE=dptCost.CDEPT_ID AND replace(eleMapping.IYPERIOD,'-','') = dptCost.IYPERIOD)
			    GROUP BY eleMapping.DEPT_CODE, eleMapping.PROD_ELE_CODE, eleMapping.DRIVER_CODE, eleMapping.IYPERIOD
				) elevalue
				UNION
				--取得硬件共用总成本：硬件共用总成本=填报+部门占用技术运行中心硬件
				SELECT @dept_id DEPT_CODE, a.PRD_ELE_CODE element_code, '1' driven_code, --共用硬件一定是按照工时进行分摊
				       --如果存在填报硬件成本：那么就相加取得总成本，否则只取部门占用技术运行中心的硬件成本
				       CASE WHEN (SELECT COUNT(1) 
					              FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
								  WHERE DEPT_CODE=@dept_id and IYPERIOD=@iyperiod and ELECODE='1002010101') > 0 
							THEN ROUND(((SELECT ISNULL(VALUE,0) * 10000 
					              FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
								  WHERE DEPT_CODE=@dept_id and IYPERIOD=@iyperiod and ELECODE='1002010101') + @shareHardCost)/10000,9)
							ELSE ROUND(@shareHardCost/10000,9)
					   END current_amount
				FROM [ESREPORT].[ODM].[COST_A_PRO_CT_ELEMENT] a
				WHERE a.IYPERIOD=@iyperiod AND a.PRD_ELE_CODE='1002010101'
				UNION 
				--取得软件共用总成本
				SELECT @dept_id DEPT_CODE,  a.PRD_ELE_CODE element_code, '1' driven_code, 
				        --如果存在填报软件共用成本：那么就相加取得总成本，否则只取部门占用技术运行中心的软件成本
				       CASE WHEN (SELECT COUNT(1) 
					              FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
								  WHERE DEPT_CODE=@dept_id and IYPERIOD=@iyperiod and ELECODE='1002010201') > 0 
							THEN ROUND(((SELECT ISNULL(VALUE,0) *10000
					              FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
								  WHERE DEPT_CODE=@dept_id and IYPERIOD=@iyperiod and ELECODE='1002010201') + @shareSoftCost)/10000,9)
							ELSE ROUND(@shareSoftCost/10000,10)
					   END current_amount
				FROM [ESREPORT].[ODM].[COST_A_PRO_CT_ELEMENT] a
				WHERE a.IYPERIOD=@iyperiod AND a.PRD_ELE_CODE='1002010201'
				ORDER BY driven_code, element_code -- 一定要保证先处理基于工时/外包工时和直接计入的成本元素，然后处理硬件占比，最后处理成本占比
			--循环处理成本元素列表
			OPEN prod_tbEles_cursor
			    FETCH NEXT FROM prod_tbEles_cursor INTO @dept_id, @prodEleCode, @driven_code, @cur_amount 
				WHILE @@FETCH_STATUS = 0
	      	        BEGIN
					    --只有当成本元素的成本金额不等于0的时候才需要进行分摊
					    IF (@cur_amount IS NOT NULL AND 
						     ((@prodEleCode NOT IN ('1001010120','1001010121') AND @cur_amount<>0) OR @prodEleCode IN ('1001010120', '1001010121') ))
						    BEGIN
							    --初始化进行尾差计算的参数值
					            SET @total_tmp = 0
		                        SET @tailCountingAmount = 0
		                        SET @tailTotalAmount = 0
								SET @totalInputValue = 0
								SET @checkDigit=0
								--需要对彩票信息部和大客户部的办公费成本金额进行调整
								IF (@dept_id = '6')  --处理彩票信息部的办公费
								    BEGIN 
									   --处理成本元素"稿费"： 彩票信息部将'稿费'从办公费中单独分离出来了，但是从部门全成本中取办公费的时候
									   --已经包含了稿费，所以在处理彩票信息部的时候，需要将稿费从办公费中减去
									   IF(@prodEleCode = '1001010120')
									       BEGIN
										       --判断稿费是否已经取得
										       IF(@writeAmount IS NULL OR @writeAmount = 0)
											       BEGIN
												       --从部门全成本表中取得稿费的具体成本 -- 部门全成本视图中不包含稿费，只能从部门全成本表中取得
											           SELECT @writeAmount=ROUND(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/10000,9)
											           FROM [ODM].[COST_DEPT_FULL_COSTING] a												
											           WHERE a.CDEPT_ID=@dept_id AND 												        
											                 a.IYPERIOD=REPLACE(@iyperiod, '-','') AND
													         a.CT_CODE IN ('52','25.1')

											           IF (@writeAmount IS NULL)
												           BEGIN
													           SET @writeAmount = 0
													       END
												   END
											   --重新设置稿费的金额amount
											   SET @cur_amount = @writeAmount
										   END
									   ELSE IF (@prodEleCode = '1001010110')
									       BEGIN
										       --判断稿费是否已经取得
										       IF(@writeAmount IS NULL OR @writeAmount = 0)
											       BEGIN
												       --取得稿费的具体成本
											           SELECT @writeAmount=ROUND(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/10000,9)
											           FROM [ODM].[COST_DEPT_FULL_COSTING] a
											           WHERE a.CDEPT_ID=@dept_id AND 
											                 a.IYPERIOD=REPLACE(@iyperiod, '-','') AND
													         a.CT_CODE IN ('52','25.1')

											           IF (@writeAmount IS NULL)
												           BEGIN
													           SET @writeAmount = 0
													       END
												   END
											   --重新设置办公费amount：需要减去稿费的金额
											   SET @cur_amount = @cur_amount - @writeAmount										       
										   END
									END
								ELSE IF (@dept_id = '9') --处理大客户部的办公费的特殊情况
								    BEGIN 
									   --处理成本元素"采购Key成本"： 大客户部将'采购Key成本'从办公费中单独分离出来了，但是从部门全成本中取办公费的时候
									   --已经包含了采购Key成本，所以在处理大客户部的时候，需要将采购Key成本从办公费中减去
									   IF(@prodEleCode = '1001010121')
									       BEGIN
										       --判断采购key是否已经取得
										       IF(@purchageAmount IS NULL OR @purchageAmount = 0)
											       BEGIN
												       --从部门全成本表中取得采购Key的具体成本 -- 部门全成本视图中不包含采购Key，只能从部门全成本表中取得
											           SELECT @purchageAmount=ROUND(ISNULL(a.CUR_AMOUNT,0)/10000,9)
											           FROM [ODM].[COST_DEPT_FULL_COSTING] a
											           WHERE a.CDEPT_ID=@dept_id AND 
											                 a.IYPERIOD=REPLACE(@iyperiod, '-','') AND
													         a.CT_CODE = '49'

											           IF (@purchageAmount IS NULL)
												           BEGIN
													           SET @purchageAmount = 0
													       END
												   END
											   --重新设置采购Keyamount
											   SET @cur_amount = @purchageAmount
										   END
									   ELSE IF (@prodEleCode = '1001010110') --处理大客户部下的办公费
									       BEGIN
										       --判断采购Key是否已经取得
										       IF(@purchageAmount IS NULL OR @purchageAmount = 0)
											       BEGIN
												       --取得采购Key的具体成本
											           SELECT @purchageAmount=ROUND(ISNULL(a.CUR_AMOUNT,0)/10000,9)
											           FROM [ODM].[COST_DEPT_FULL_COSTING] a
											           WHERE a.CDEPT_ID=@dept_id AND 
											                 a.IYPERIOD=REPLACE(@iyperiod, '-','') AND
													         a.CT_CODE = '49'

											           IF (@purchageAmount IS NULL)
												           BEGIN
													           SET @purchageAmount = 0
													       END
												   END
											   --重新设置办公费amount
											   SET @cur_amount = @cur_amount - @purchageAmount										       
										   END
									END
								--根据不同的进行成本的分摊：1：工时， 2：直接计入， 3：硬件占比， 4：成本占比-除动因是成本占比的成本元素之外的成本总和占比
						        --处理动因是工时的成本元素
								IF (@driven_code ='1' AND 0 < @deptTotalWorkingHour)
						            BEGIN
							            --取得该部门下产品/服务以及工时占比
										IF (@dept_id = '204' OR @dept_id='3') --技术运行中心和测试部分摊需要特殊处理:工时需要从运维/测试工时填报表中取得
										   BEGIN
										       --取得每个服务所对应的总工时与整个部门总工时占比
										       DECLARE special_prod_srv_list_cursor CURSOR FOR
											       SELECT a.SERVICE_KEY, round(ISNULL(a.WORKING_VALUE,0)/@deptTotalWorkingHour,9) percentage
												   FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T  a
												   WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.PRODUCT_KEY='0'
										       OPEN special_prod_srv_list_cursor
											   FETCH NEXT FROM special_prod_srv_list_cursor INTO @prodSrvKey, @rate
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
						                              --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                      INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                              VALUES (@dept_id
										                         ,@prodSrvKey
										                         ,@prodEleCode
				                                                 ,ISNULL(@tailCountingAmount,0)
								                                 ,@iyperiod)
							                          SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                  SET @total_tmp =  @total_tmp + @rate
				                                      FETCH NEXT FROM special_prod_srv_list_cursor INTO @prodSrvKey, @rate
												  END
										       CLOSE special_prod_srv_list_cursor
											   DEALLOCATE special_prod_srv_list_cursor
										   END 
										ELSE 
										   BEGIN
										       --取得服务总工时与部门总工时的占比											
											   DECLARE prod_serv_list_cursor CURSOR FOR
			                                       SELECT a.PROD_SRV_KEY, round(CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))/@deptTotalWorkingHour,9) percentage
				                                   FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
				                                   WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.PROD_SRV_KEY<>'0'
												       and a.ACTIVITYORGROUP_TYPE=@isUseActivityHour
				                                   GROUP BY a.PROD_SRV_KEY
			                                   OPEN prod_serv_list_cursor
			                                   FETCH NEXT FROM prod_serv_list_cursor INTO @prodSrvKey, @rate --循环处理每个产品/服务
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
						                               --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                       INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                               VALUES (@dept_id
										                          ,@prodSrvKey
										                          ,@prodEleCode
				                                                  ,ISNULL(@tailCountingAmount,0)
								                                  ,@iyperiod)

							                            SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                    SET @total_tmp =  @total_tmp + @rate
				                                        FETCH NEXT FROM prod_serv_list_cursor INTO @prodSrvKey, @rate
					                               END
			                                   CLOSE prod_serv_list_cursor
			                                   DEALLOCATE prod_serv_list_cursor
										   END
							        END
						        --处理动因是硬件占比的成本元素
								ELSE IF (@driven_code ='3')
						            BEGIN
									    SET @totalHardwareCost=0
									    --取得硬件总成本： 硬件总成本=硬件共用成本+硬件非共用成本
										SELECT @totalHardwareCost=CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))
										FROM ODM.COST_A_PROD_DIV_LEVELONE a
										WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.PRD_ELE_CODE IN ('1002010101','1002010102') 
										--只用当总硬件成本不等于0才进行分摊
										IF (@totalHardwareCost IS NOT NULL AND @totalHardwareCost <> 0 )
										    BEGIN	
											    --取得该部门下产品/服务的硬件占比
			                                    DECLARE prod_serv_hardware_cursor CURSOR FOR
										            SELECT a.PRD_SRV_KEY, round(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/@totalHardwareCost,9) percentage
				                                    FROM ODM.COST_A_PROD_DIV_LEVELONE a
				                                    WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.PRD_ELE_CODE IN ('1002010101','1002010102')
				                                    GROUP BY a.PRD_SRV_KEY

											    OPEN prod_serv_hardware_cursor
			                                    FETCH NEXT FROM prod_serv_hardware_cursor INTO @prodSrvKey, @rate --循环处理每个产品/服务
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
						                                --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中	  
				                                        INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                VALUES (@dept_id
										                           ,@prodSrvKey
										                           ,@prodEleCode
				                                                   ,@tailCountingAmount
								                                   ,@iyperiod)

							                            SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                    SET @total_tmp =  @total_tmp + @rate
				                                        FETCH NEXT FROM prod_serv_hardware_cursor INTO @prodSrvKey, @rate
					                                END
			                                    CLOSE prod_serv_hardware_cursor
			                                    DEALLOCATE prod_serv_hardware_cursor
											END
							        END
						        --处理动因是直接计入的成本元素：直接计入的计算方式的还是，服务/产品填报成本/填报总工时
							    ELSE IF(@driven_code = '2')
						            BEGIN
									    --因为测试部在统计直接接入的成本时，是按照产品维度进行的所以需要特殊处理
										IF (@dept_id = '204')
										    BEGIN
											    --从服务-产品-动因表中取得直接计入的总数
												SET @totalInputValue = 0
												SELECT @totalInputValue=CAST(SUM(ISNULL(a.WORKING_VALUE, 0)) AS DECIMAL(28,10))
									            FROM [ODM].[COST_A_SRV_PROD_DRIVER_MAP_T] a  -- 直接动因
									            WHERE a.DEPT_CODE=@dept_id and a.PROD_ELE_CODE=@prodEleCode and a.IYPERIOD=@iyperiod
												      --PRODUCT_KEY=0表示取得是服务下产品直接计入填报的总数
												      and a.PRODUCT_KEY='0'
												--当直接计入总额不等于0的时候,才进行分摊
										        IF (@totalInputValue IS NOT NULL AND @totalInputValue<>0 )
                                                    BEGIN
											            --取得测试部门下产品/服务填报动因比例
											            DECLARE prod_srv_direct_driver_cursor CURSOR FOR
								                            SELECT a.SERVICE_KEY, round(a.WORKING_VALUE/@totalInputValue,9) percentage
									                        FROM [ODM].[COST_A_SRV_PROD_DRIVER_MAP_T] a
									                        WHERE a.DEPT_CODE=@dept_id and a.PROD_ELE_CODE=@prodEleCode and a.IYPERIOD=@iyperiod
															      AND a.PRODUCT_KEY='0'
                                                        OPEN prod_srv_direct_driver_cursor
							                            FETCH NEXT FROM prod_srv_direct_driver_cursor INTO @prodSrvKey, @rate --循环处理每个产品/服务
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
						                                        --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                                INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                        VALUES (@dept_id
										                                   ,@prodSrvKey
										                                   ,@prodEleCode
				                                                           ,@tailCountingAmount
								                                           ,@iyperiod)

							                                    SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                            SET @total_tmp =  @total_tmp + @rate
				                                                FETCH NEXT FROM prod_srv_direct_driver_cursor INTO @prodSrvKey, @rate
					                                        END
			                                            CLOSE prod_srv_direct_driver_cursor
			                                            DEALLOCATE prod_srv_direct_driver_cursor
											        END
											END
										ELSE
										    BEGIN
											    --取得直接计入填报总数:除测试部之外，其他部门的直接计入填报都是基于服务的，
												--从[COST_A_DEPT_ELE_MAP_T]填报表中取得
												SET @totalInputValue = 0
										        SELECT @totalInputValue=CAST(SUM(ISNULL(a.DRIVER_VALUE, 0)) AS DECIMAL(28,10))
									            FROM [ODM].[COST_A_DEPT_ELE_MAP_T] a  -- 直接动因
									            WHERE a.DEPT_CODE=@dept_id and a.ELE_CODE=@prodEleCode and a.IYPERIOD=@iyperiod
												--当直接计入总额不等于0的时候,才进行分摊
										        IF (@totalInputValue IS NOT NULL AND @totalInputValue<>0 )
										            BEGIN
											            --取得该部门下产品/服务填报动因比例
											            DECLARE prod_srv_direct_driver_cursor CURSOR FOR
								                            SELECT a.PRODORSERVE_KEY, round(ISNULL(a.DRIVER_VALUE,0)/@totalInputValue,9) percentage
									                        FROM [ODM].[COST_A_DEPT_ELE_MAP_T] a
									                        WHERE a.DEPT_CODE=@dept_id and a.ELE_CODE=@prodEleCode and a.IYPERIOD=@iyperiod
                                                        OPEN prod_srv_direct_driver_cursor
							                            FETCH NEXT FROM prod_srv_direct_driver_cursor INTO @prodSrvKey, @rate --循环处理每个产品/服务
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
						                                        --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                                INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                        VALUES (@dept_id
										                                   ,@prodSrvKey
										                                   ,@prodEleCode
				                                                           ,@tailCountingAmount
								                                           ,@iyperiod)

							                                    SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                            SET @total_tmp =  @total_tmp + @rate
				                                                FETCH NEXT FROM prod_srv_direct_driver_cursor INTO @prodSrvKey, @rate
					                                        END
			                                            CLOSE prod_srv_direct_driver_cursor
			                                            DEALLOCATE prod_srv_direct_driver_cursor
											        END
											END
							        END
					            --处理动因为成本占比的成本元素
					            ELSE IF(@driven_code = '4')
						            BEGIN
							            --取得除基于成本占比成本元素之外的各个产品/服务的成本元素总和
										SET @totalDeptCost = 0
								        SELECT @totalDeptCost=CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))
								        FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
										     ,[ODM].[COST_A_DEPT_ELE_MAP] b
								        WHERE   a.DEPT_CODE = b.DEPT_CODE and a.IYPERIOD=b.IYPERIOD
										    and a.PRD_ELE_CODE = b.ELE_CODE
										    and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod 
											and b.DRIVER_CODE<>'4'  --不能取得是成本占比的元素
	
							            --取得该部门下产品/服务以及成本占比
										IF (@totalDeptCost IS NOT NULL AND @totalDeptCost <> 0)
										    BEGIN
											    DECLARE prod_srv_cost_driven_cursor CURSOR FOR
			                                        SELECT a.PRD_SRV_KEY, round(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/@totalDeptCost,9) percentage
				                                    FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a, ODM.COST_A_DEPT_ELE_MAP b
				                                    WHERE a.DEPT_CODE=b.DEPT_CODE and a.IYPERIOD=b.IYPERIOD 
											          and a.PRD_ELE_CODE = b.ELE_CODE and										
											              a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and b.DRIVER_CODE<>'4'
				                                    GROUP BY a.DEPT_CODE, a.IYPERIOD, a.PRD_SRV_KEY

			                                    OPEN prod_srv_cost_driven_cursor
			                                    FETCH NEXT FROM prod_srv_cost_driven_cursor INTO @prodSrvKey, @rate --循环处理每个产品/服务
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
						                                --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                        INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                VALUES (@dept_id
										                           ,@prodSrvKey
										                           ,@prodEleCode
				                                                   ,@tailCountingAmount
								                                   ,@iyperiod)
							                            SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                    SET @total_tmp = @total_tmp + @rate

				                                        FETCH NEXT FROM prod_srv_cost_driven_cursor INTO @prodSrvKey, @rate
					                                END
			                                    CLOSE prod_srv_cost_driven_cursor
			                                    DEALLOCATE prod_srv_cost_driven_cursor
											END
							        END
							END
					   
					    FETCH NEXT FROM prod_tbEles_cursor INTO @dept_id, @prodEleCode, @driven_code,@cur_amount 
					END
			CLOSE prod_tbEles_cursor
			DEALLOCATE prod_tbEles_cursor

			FETCH NEXT FROM proc_dept_curcor INTO @dept_id, @iyperiod --循环处理各个部门
		END
CLOSE proc_dept_curcor
DEALLOCATE proc_dept_curcor
--以部门维度进行第一次分摊-End

--开始进行二次分摊 --START
IF (@iyperiod IS NULL OR @iyperiod = '')
    BEGIN
	    SET @iyperiod = @max_iyperiod
	END 
--部门进行二次分摊-服务分摊到成本上
DECLARE @service_totalAmount decimal(28,10)  --用于保存除成本占比成本元素之外的所有元素成本之后

--填报过了服务对应到产品的工时，那就需要将服务分摊到产品上
--1.技术运行中心： 按照产品占运维服务的工时占比，分摊所有服务的成本
--2.测试部： 需要根据不同的成本元素动因进行二次分摊
DECLARE second_div_dept_cursor CURSOR FOR
    --取得当前会计期间需要进行二次分摊的部门
    SELECT DISTINCT a.DEPT_CODE
	FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
	WHERE a.IYPERIOD = @iyperiod
--打开部门cursor
OPEN second_div_dept_cursor 
FETCH NEXT FROM second_div_dept_cursor INTO @dept_id
WHILE @@FETCH_STATUS = 0
    BEGIN
	    --由于测试部门和其他部门的二次分摊流程处理方式不同个，那么需要对测试部门进行处理
		--测试部： 各个成本元素需要按照动因类型采用不同的成本分摊方式
		--技术运行中心： 所有的成本元素都按照产品工时占比进行分摊		
	    IF(@dept_id = '204') --处理测试部门
	        BEGIN
			    --按照测试服务循环处理非成本占比元素 --因为成本占比元素需要基于非成本占比元素成本总和来计算，所以一定是先处理非成本占比元素
				--第一次服务循环，处理非成本占比成本元素
			    DECLARE second_div_service_cursor CURSOR FOR
                    SELECT DISTINCT a.PRD_SRV_KEY
	                FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
		            WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD = @iyperiod
			    OPEN second_div_service_cursor
                FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
                WHILE @@FETCH_STATUS = 0
				    BEGIN
					    --按照成本元素循环处理 -- 第一次循环只处理非成本占比元素
				        --取得服务下产品总工时
						SET @deptTotalWorkingHour=0
		                SELECT  @deptTotalWorkingHour=ISNULL(a.WORKING_VALUE,0)
		                FROM  ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
		                WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey 
						  and a.PRODUCT_KEY='0'

						--判断该服务是否有对应的产品，如果没有，不需要进行二次分摊
						SET @checkDigit = 0
						SELECT @checkDigit=COUNT(1)
						FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
						WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey
						      and a.PRODUCT_KEY <> '0'

					    IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
						    BEGIN
							    --循环处理每个成本元素
		                        DECLARE second_div_element_code_cursor CURSOR FOR
		                            SELECT a.PRD_ELE_CODE, b.DRIVER_CODE, a.CUR_AMOUNT
			                        FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a,
			                             ODM.COST_A_DEPT_ELE_MAP b
		                            WHERE a.DEPT_CODE = b.DEPT_CODE and a.PRD_ELE_CODE=b.ELE_CODE and a.IYPERIOD = b.IYPERIOD			
			                          and a.DEPT_CODE=@dept_id and a.PRD_SRV_KEY=@prodSrvKey and a.IYPERIOD=@iyperiod and b.DRIVER_CODE<>'4'
		                            ORDER BY b.DRIVER_CODE
	                            OPEN second_div_element_code_cursor
		                        FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @driven_code, @cur_amount 
                                WHILE @@FETCH_STATUS = 0
						            BEGIN
							            SET @total_tmp = 0
		                                SET @tailCountingAmount = 0
		                                SET @tailTotalAmount = 0
		                                SET @totalInputValue = 0
								        --处理动因是工时的成本元素
						                IF(@driven_code = '1' OR @driven_code = '3')
										    BEGIN
											    IF (@deptTotalWorkingHour IS NOT NULL AND @deptTotalWorkingHour<>0)
											        BEGIN												
						                                DECLARE test_products_cursor CURSOR FOR
		                                                    SELECT a.PRODUCT_KEY, round(ISNULL(a.WORKING_VALUE,0)/@deptTotalWorkingHour,9) percentage
			                                                FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
			                                                WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey
								                              and a.PRODUCT_KEY <> '0'
			                                            OPEN test_products_cursor
							                            FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
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
				                                                --将部门该服务下的产品占用成本元素的成本插入COST_A_PROD_DIV_LEVELTWO表中		    
			                                                    INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELTWO](DEPT_CODE, SRV_KEY, PROD_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                         VALUES (@dept_id
						                                                    ,@prodSrvKey
						                                                    ,@product_key
						                                                    ,@prodEleCode
				                                                            ,@tailCountingAmount
						                                                    ,@iyperiod)
				                                                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                            SET @total_tmp =  @total_tmp + @rate
			                                                    FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
								                             END
								                        CLOSE test_products_cursor
								                        DEALLOCATE test_products_cursor
						                            END
											END
						                ELSE IF(@driven_code = '2')  --处理动因是直接计入的成本元素
						                    BEGIN
							                    --取得直接计入的总和
												SET @totalInputValue=0
								                SELECT @totalInputValue=ISNULL(a.WORKING_VALUE, 0)
								                FROM [ODM].[COST_A_SRV_PROD_DRIVER_MAP_T] a
								                WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey
								                  and a.PROD_ELE_CODE = @prodEleCode and PRODUCT_KEY='0'

								                IF (@totalInputValue IS NOT NULL AND @totalInputValue<>0)
								                    BEGIN
													    --循环处理服务下的每个产品
								                        DECLARE test_input_products_cursor CURSOR FOR
		                                                    SELECT a.PRODUCT_KEY, round(ISNULL(a.WORKING_VALUE,0)/@totalInputValue,9) percentage
			                                                FROM [COST_A_SRV_PROD_DRIVER_MAP_T] a
			                                                WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey and a.PRODUCT_KEY<>'0'
			                                            OPEN test_input_products_cursor
							                            FETCH NEXT FROM test_input_products_cursor INTO @product_key, @rate
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
				                                                --将部门该服务下的产品的成本元素成本插入COST_A_PROD_DIV_LEVELTWO 表中		    
			                                                    INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELTWO](DEPT_CODE, SRV_KEY, PROD_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                                        VALUES (@dept_id
						                                                   ,@prodSrvKey
						                                                   ,@product_key
						                                                   ,@prodEleCode
				                                                           ,@tailCountingAmount
						                                                   ,@iyperiod)
				                                                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                                            SET @total_tmp =  @total_tmp + @rate
			                                                    FETCH NEXT FROM test_input_products_cursor INTO @product_key, @rate
								                            END
								                        CLOSE test_input_products_cursor
								                        DEALLOCATE test_input_products_cursor
									                END
							                END

							            FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @driven_code, @cur_amount 
							        END 
						        CLOSE second_div_element_code_cursor
						        DEALLOCATE second_div_element_code_cursor
							END

						FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
					END
				CLOSE second_div_service_cursor
				DEALLOCATE second_div_service_cursor

				--按照服务列表进行第二次循环处理成本占比元素
				--取得非成本占比元素成本总和
				SET @service_totalAmount=0
				SELECT @service_totalAmount=CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))
				FROM [ODM].COST_A_PROD_DIV_LEVELONE a,
				      ODM.COST_A_DEPT_ELE_MAP b
		        WHERE a.DEPT_CODE = b.DEPT_CODE and a.PRD_ELE_CODE=b.ELE_CODE and a.IYPERIOD = b.IYPERIOD		
			          and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and b.DRIVER_CODE<>'4'

                IF (@service_totalAmount IS NOT NULL AND @service_totalAmount <> 0)
				    BEGIN
					    --取得基于成本元素占比的成本元素列表-循环处理
		                DECLARE second_div_element_code_cursor CURSOR FOR
		                    SELECT a.PRD_ELE_CODE, CAST(SUM(ISNULL(a.CUR_AMOUNT, 0)) AS DECIMAL(28,10))
			                FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a,
			                     ODM.COST_A_DEPT_ELE_MAP b
		                    WHERE   a.DEPT_CODE = b.DEPT_CODE and a.PRD_ELE_CODE=b.ELE_CODE and a.IYPERIOD = b.IYPERIOD			
			                    and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and b.DRIVER_CODE='4'
							GROUP BY a.PRD_ELE_CODE
				        --打开成本元素CURSOR
	                    OPEN second_div_element_code_cursor
		                FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @cur_amount 
                        WHILE @@FETCH_STATUS = 0
				            BEGIN
				                SET @total_tmp = 0
		                        SET @tailCountingAmount = 0
		                        SET @tailTotalAmount = 0
		                        SET @totalInputValue = 0
						        --按照部门下服务列表进行循环处理
			                    DECLARE second_div_service_cursor CURSOR FOR
                                    SELECT DISTINCT a.PRD_SRV_KEY
	                                FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
		                            WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD = @iyperiod
						        --打开服务cursor
			                    OPEN second_div_service_cursor
                                FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
                                WHILE @@FETCH_STATUS = 0
					                BEGIN
							            --循环处理服务下对应的每个产品
						                DECLARE test_products_cursor CURSOR FOR
		                                    SELECT a.PROD_KEY, round(CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10))/@service_totalAmount,9) percentage
			                                FROM [ODM].[COST_A_PROD_DIV_LEVELTWO] a, ODM.COST_A_DEPT_ELE_MAP b
							                WHERE a.DEPT_CODE = b.DEPT_CODE and a.IYPERIOD = b.IYPERIOD and a.ELE_CODE=b.ELE_CODE
										      and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SRV_KEY=@prodSrvKey
								              and b.DRIVER_CODE<>'4'
									        GROUP BY a.PROD_KEY
								        --打开产品cursor
			                            OPEN test_products_cursor
							            FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
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
			    				                --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
			                                    INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELTWO](DEPT_CODE, SRV_KEY, PROD_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                        VALUES (@dept_id
						                                   ,@prodSrvKey
						                                   ,@product_key
						                                   ,@prodEleCode
				                                           ,@tailCountingAmount
						                                   ,@iyperiod)
				                                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                            SET @total_tmp =  @total_tmp + @rate
			                                    FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
								            END
							            CLOSE test_products_cursor
								        DEALLOCATE test_products_cursor					      
								        --取得下一个服务
							            FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
							        END
						        --关闭服务cursor
						        CLOSE second_div_service_cursor
						        DEALLOCATE 	second_div_service_cursor
					            --取得下一个成本占比元素
					            FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @cur_amount 
					        END
				        --关闭成本元素cursor
				        CLOSE second_div_element_code_cursor
				        DEALLOCATE second_div_element_code_cursor
					END
		    END
		ELSE  --处理其他部门：所有成本元素都按照产品工时占比进行二次分摊
		    BEGIN
				--首先取得该部门下面所有需要进行二次分摊的服务列表
			    DECLARE second_div_service_cursor CURSOR FOR
                    SELECT DISTINCT a.PRD_SRV_KEY
	                FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
		            WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD = @iyperiod
				--打开服务列表cursour
			    OPEN second_div_service_cursor
                FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
                WHILE @@FETCH_STATUS = 0
				    BEGIN
						--取得服务对应产品的总工时
						SET @deptTotalWorkingHour=0
		                SELECT  @deptTotalWorkingHour=ISNULL(a.WORKING_VALUE,0)
		                FROM  ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
		                WHERE  a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey 
						      --PRODUCT_KEY='0'用于查询特定服务下所有产品工时的总和
						   and a.PRODUCT_KEY='0'

						--判断该服务是否有对应的产品，如果没有，不需要进行二次分摊
						SET @checkDigit = 0
						SELECT @checkDigit=COUNT(1)
						FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
						WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.SERVICE_KEY=@prodSrvKey
						      and a.PRODUCT_KEY <> '0'

						IF (@checkDigit IS NOT NULL AND 0 < @checkDigit AND @deptTotalWorkingHour IS NOT NULL AND @deptTotalWorkingHour <> 0)
						    BEGIN
							    --循环处理服务下面每个成本元素
		                        DECLARE second_div_element_code_cursor CURSOR FOR
		                            SELECT a.PRD_ELE_CODE, a.CUR_AMOUNT
			                        FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
		                            WHERE  a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.PRD_SRV_KEY=@prodSrvKey
						        --打开成本元素cursor
	                            OPEN second_div_element_code_cursor
		                        FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @cur_amount 
                                WHILE @@FETCH_STATUS = 0
						            BEGIN
							            SET @total_tmp = 0
		                                SET @tailCountingAmount = 0
		                                SET @tailTotalAmount = 0
		                                SET @totalInputValue = 0
								        --循环处理服务下对应的每个产品
						                DECLARE test_products_cursor CURSOR FOR
		                                    SELECT a.PRODUCT_KEY, round(ISNULL(a.WORKING_VALUE,0)/@deptTotalWorkingHour,9) percentage
			                                FROM ODM.COST_A_DEPT_SRV_FOR_PROD_MAP_T a
			                                WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and
									              a.SERVICE_KEY = @prodSrvKey and a.PRODUCT_KEY <> '0'
			                            OPEN test_products_cursor
							            FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
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
			    
				                                --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
			                                    INSERT INTO [ODM].[COST_A_PROD_DIV_LEVELTWO](DEPT_CODE, SRV_KEY, PROD_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                        VALUES (@dept_id
						                                   ,@prodSrvKey
						                                   ,@product_key
						                                   ,@prodEleCode
				                                           ,@tailCountingAmount
						                                   ,@iyperiod)
				                                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                            SET @total_tmp =  @total_tmp + @rate
			                                    FETCH NEXT FROM test_products_cursor INTO @product_key, @rate
								            END
								        CLOSE test_products_cursor
								        DEALLOCATE test_products_cursor
								        --取得下一条成本元素
							            FETCH NEXT FROM second_div_element_code_cursor INTO @prodEleCode, @cur_amount 
							        END 
						        --关闭成本元素cursor
						        CLOSE second_div_element_code_cursor
						        DEALLOCATE second_div_element_code_cursor
							END
					    --取得下一个服务
						FETCH NEXT FROM second_div_service_cursor INTO @prodSrvKey  --循环处理每个产品/服务
					END
				--关闭服务列表cursor
				CLOSE second_div_service_cursor
				DEALLOCATE second_div_service_cursor
            END 
        --取得下一条需要进行二次分摊的数据
		FETCH NEXT FROM second_div_dept_cursor INTO @dept_id
	END
--关闭部门cursor
CLOSE second_div_dept_cursor
DEALLOCATE second_div_dept_cursor
--二次分摊--END

--管理部门最后进行分摊
SET @dept_id = '1'
IF (@iyperiod IS NULL OR @iyperiod = '')
    BEGIN
	    SET @iyperiod=@max_iyperiod
	END 

--取得技术运用中心下面管理部门占用硬件资产共用成本
SET @shareHardCost = 0
SELECT @shareHardCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
FROM ODM.FUN_GETASSETS(3, 0, @dept_id, @iyperiod) assets --根据函数取得固定资产信息

IF (@shareHardCost IS NULL)
    BEGIN
	    SET @shareHardCost = 0
	END

--取得技术运用中心下面部门占用无形资产共用成本
SET @shareSoftCost=0
SELECT @shareSoftCost=CAST(SUM(ISNULL(assets.dblDepr,0)) AS DECIMAL(28,10))
FROM ODM.FUN_GETASSETS(3, 1, @dept_id, @iyperiod) assets --根据函数取得固定资产信息

IF (@shareSoftCost IS NULL)
    BEGIN
	    SET @shareSoftCost = 0
	END

--取得管理部门中可以直接映射到一次分摊成本表中的产品服务成本
SELECT prodCost.PRD_SRV_KEY prodSrvCode, CAST(SUM(ISNULL(prodCost.CUR_AMOUNT,0)) AS DECIMAL(28,10)) costAmt, prodSrvs.IS_BIG_CONTRACT isBigContract INTO #directProdSrvCost
FROM  [ODM].[COST_A_PROD_DIV_LEVELONE] prodCost  
     ,(SELECT *  
	   FROM [ODM].[COST_A_DEPT_PROORSER_MAP] 
	   WHERE DEPT_CODE='1' AND IYPERIOD=@iyperiod) deptProdSrvMap
     ,[ODM].[COST_PRODUCTORSERVE] prodSrvs
WHERE prodCost.IYPERIOD = deptProdSrvMap.IYPERIOD and
	  prodCost.PRD_SRV_KEY = deptProdSrvMap.PROORSER_CODE and 
	  prodCost.PRD_SRV_KEY = prodSrvs.PRODUCTORSERVE_CODE and
	  prodCost.IYPERIOD=@iyperiod
GROUP BY prodCost.PRD_SRV_KEY, prodSrvs.IS_BIG_CONTRACT
--取得管理部门中需要通过二级到三级映射关系对应到一次分摊成本表中的产品成本
SELECT deptProdSrvMap.PROORSER_CODE prodSrvCode, CAST(SUM(ISNULL(prodCost.CUR_AMOUNT,0)) AS DECIMAL(28,10)) costAmt, prodSrvs.IS_BIG_CONTRACT isBigContract INTO #composeProdSrvCost
FROM ( SELECT a.DEPT_CODE, a.IYPERIOD, a.PROORSER_CODE
       FROM [ODM].[COST_A_DEPT_PROORSER_MAP] a
       WHERE a.DEPT_CODE = '1' and a.IYPERIOD=@iyperiod 
         and a.PROORSER_CODE NOT IN (SELECT prodSrvCode FROM #directProdSrvCost)
     ) deptProdSrvMap
     , [ODM].[COST_PRO_SER_SECOND_THIRD_MAP] srvInnerMap
     , [ODM].[COST_A_PROD_DIV_LEVELONE] prodCost
     , [ODM].[COST_PRODUCTORSERVE] prodSrvs
WHERE deptProdSrvMap.IYPERIOD = prodCost.IYPERIOD and
      deptProdSrvMap.IYPERIOD = srvInnerMap.IYPERIOD and
      deptProdSrvMap.PROORSER_CODE = srvInnerMap.SECOND_CODE and
	  srvInnerMap.THIRD_CODE = prodCost.PRD_SRV_KEY and
      prodCost.PRD_SRV_KEY = prodSrvs.PRODUCTORSERVE_CODE and
	  deptProdSrvMap.IYPERIOD=@iyperiod
GROUP BY deptProdSrvMap.PROORSER_CODE, prodSrvs.IS_BIG_CONTRACT

DECLARE @fun_prodSrv_TotalCost decimal(28,10)
DECLARE @fun_Big_ProdSrv_TotalCost decimal(28,10)
DECLARE @func_activity_code VARCHAR(20)

--取得管理部门对应的所有产品和服务的总成本
SELECT @fun_prodSrv_TotalCost=CAST(SUM(ISNULL(prodSrvCostList.prodSrvAmount,0)) AS DECIMAL(28,10))
FROM ( SELECT costAmt prodSrvAmount
       FROM #directProdSrvCost a
       UNION
       SELECT b.costAmt prodSrvAmount
       FROM #composeProdSrvCost b
     ) prodSrvCostList

IF (@fun_prodSrv_TotalCost IS NULL)
    BEGIN
	   SET @fun_prodSrv_TotalCost = 0
	END

--取得管理部门属于大合同范畴的所有产品和服务的总成本
SELECT @fun_Big_ProdSrv_TotalCost=CAST(SUM(ISNULL(prodSrvCostList.prodSrvAmount,0)) AS DECIMAL(28,10))
FROM ( SELECT costAmt prodSrvAmount
       FROM #directProdSrvCost a
	   WHERE a.isBigContract='Y'
       UNION
       SELECT b.costAmt prodSrvAmount
       FROM #composeProdSrvCost b
	   WHERE b.isBigContract='Y'
     ) prodSrvCostList

IF (@fun_Big_ProdSrv_TotalCost IS NULL)
    BEGIN
	   SET @fun_Big_ProdSrv_TotalCost = 0
	END


DECLARE @inner_total_tmp decimal(28, 10)
DECLARE @inner_tailCountingAmount decimal(28,10)
DECLARE @inner_tailTotalAmount decimal(28,10)
DECLARE @inner_workingHours decimal (28,10)
DECLARE @inner_rate decimal (28,10)
DECLARE @inner_dept_code VARCHAR(20)
--循环处理管理部门的成本元素
DECLARE func_dept_ele_cost_cursor CURSOR FOR
    SELECT '1' DEPT_CODE, unionCost.prod_ele_code PROD_ELE_CODE, unionCost.period IYPERIOD,  CAST(SUM(ISNULL(unionCost.current_amount,0)) AS DECIMAL(28,10)) CUR_AMOUNT
    FROM ( --只能部门除企业信息化成本
	       --取得职能部门除企业信息化部的直接成本
	       SELECT @dept_id dept_code, eleMapping.PROD_ELE_CODE prod_ele_code, eleMapping.IYPERIOD period, CAST(SUM(ISNULL(dptCost.cur_amount,0)) AS DECIMAL(28,10)) current_amount
		   FROM ( SELECT b.DEPT_CODE DEPT_CODE, b.SOURCE_DEPT_CODE, b.DRIVER_CODE, b.ELE_CODE PROD_ELE_CODE, b.IYPERIOD, a.CT_CODE DEPT_ELE_CODE
                  FROM  [ODM].[COST_A_PROELE_CTELE_MAP] a,
                        ( SELECT prcEleDepMap.DEPT_CODE, deptMap.SOURCE_DEPT_CODE, prcEleDepMap.DRIVER_CODE,prcEleDepMap.ELE_CODE,prcEleDepMap.IYPERIOD
                          FROM   [ODM].[COST_A_DEPT_ELE_MAP] prcEleDepMap
                                ,ODM.COST_A_PROD_INNER_DEPT_MAPPING deptMap--该表用于产品全成本从部门全成本取值的部门映射，如研发中心是由研发一部研发二部以及研发管理部组成
                          WHERE  prcEleDepMap.DEPT_CODE = deptMap.PRODCOST_DEPT_CODE
                             AND prcEleDepMap.DEPT_CODE = @dept_id
		                     AND prcEleDepMap.IYPERIOD = @iyperiod
		                     AND prcEleDepMap.ELE_CODE NOT IN ('10020101','10020102','1002010102', '1002010201', '1002010101', '1002010202')
	                     ) b
                       WHERE a.PRO_ELE_CODE = b.ELE_CODE
			         ) eleMapping LEFT JOIN [ODM].[COM_COST_ELE_DETAILS] dptCost ON (eleMapping.DEPT_ELE_CODE = dptCost.code AND eleMapping.SOURCE_DEPT_CODE=dptCost.CDEPT_ID AND replace(eleMapping.IYPERIOD,'-','') = dptCost.IYPERIOD)
			    GROUP BY eleMapping.PROD_ELE_CODE, eleMapping.DRIVER_CODE, eleMapping.IYPERIOD
	       --取得管理部门硬件共用总成本  10-18  update:DEPT_CODE=@dept_id --> DEPT_CODE in ('1','8') 
	       UNION
	       SELECT @dept_id dept_code, a.PRD_ELE_CODE prod_ele_code, a.IYPERIOD period,
		 	      CASE WHEN (SELECT COUNT(1) 
					         FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
						     WHERE DEPT_CODE in ('1','8') and IYPERIOD=@iyperiod and ELECODE='1002010101') > 0 
				       THEN ROUND(((SELECT SUM(ISNULL(VALUE,0)) * 10000 
					         FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
						     WHERE DEPT_CODE in ('1','8') and IYPERIOD=@iyperiod and ELECODE='1002010101') + @shareHardCost)/10000,9)
				       ELSE ROUND(@shareHardCost/10000,9)
			      END current_amount
	       FROM [ESREPORT].[ODM].[COST_A_PRO_CT_ELEMENT] a
	       WHERE a.IYPERIOD=@iyperiod AND a.PRD_ELE_CODE='1002010101'
	       --取得管理部门软件共用总成本
	       UNION 
	       SELECT @dept_id dept_code,  a.PRD_ELE_CODE prod_ele_code, a.IYPERIOD period,
			      CASE WHEN (SELECT COUNT(1) 
					         FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
						     WHERE DEPT_CODE in ('1','8') and IYPERIOD=@iyperiod and ELECODE='1002010201') > 0 
				       THEN  ROUND(((SELECT SUM(ISNULL(VALUE,0))*10000
					         FROM [ESREPORT].[ODM].[COST_A_DEPT_HARD_SOFT_MAP]
					         WHERE DEPT_CODE in ('1','8') and IYPERIOD=@iyperiod and ELECODE='1002010201') + @shareSoftCost)/10000,9)
			           ELSE ROUND(@shareSoftCost/10000,9)
			      END current_amount
	       FROM [ESREPORT].[ODM].[COST_A_PRO_CT_ELEMENT] a
	       WHERE a.IYPERIOD=@iyperiod AND a.PRD_ELE_CODE='1002010201'
	       --企业信息化部成本
           UNION    
           SELECT a.DEPT_CODE dept_code, a.PRD_ELE_CODE prod_ele_code, a.IYPERIOD period, CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10)) current_amount
           FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
           WHERE a.DEPT_CODE='106' and a.IYPERIOD=@iyperiod and a.PRD_SRV_KEY IN ('30100601', '30100602', '30100603', '30100604','30100605','30100605','30100607','30100608')
           GROUP BY a.DEPT_CODE, a.PRD_ELE_CODE, a.IYPERIOD
	       UNION
           --架构部
           SELECT a.DEPT_CODE dept_code, a.PRD_ELE_CODE prod_ele_code, a.IYPERIOD period, CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10)) current_amount
           FROM [ODM].[COST_A_PROD_DIV_LEVELONE] a
           WHERE a.DEPT_CODE='107' and a.IYPERIOD=@iyperiod and a.PRD_SRV_KEY IN ('30011203')
	       GROUP BY a.DEPT_CODE, a.PRD_ELE_CODE, a.IYPERIOD
	     ) unionCost
    GROUP BY unionCost.prod_ele_code, unionCost.period
--打开管理部门成本元素cursor
OPEN func_dept_ele_cost_cursor
FETCH NEXT FROM func_dept_ele_cost_cursor INTO @dept_id, @prodEleCode, @iyperiod, @cur_amount
WHILE @@FETCH_STATUS = 0 
    BEGIN
	    SET @total_tmp = 0
		SET @tailCountingAmount = 0
		SET @tailTotalAmount = 0
		SET @totalInputValue = 0
	    --职能部门按照产品服务维度进行分摊--START
		IF ( (@prodEleCode='1001010204' AND @fun_Big_ProdSrv_TotalCost IS NOT NULL AND @fun_Big_ProdSrv_TotalCost<>0)
		    OR (@prodEleCode<>'1001010204' AND @fun_prodSrv_TotalCost IS NOT NULL AND @fun_prodSrv_TotalCost <>0))
		    BEGIN
			    DECLARE fun_prod_srv_list CURSOR FOR
		            SELECT prodSrvCostList.prodSrvCode,
			               CASE WHEN (@prodEleCode='1001010204') 
				                    THEN round(ISNULL(prodSrvCostList.costAmt,0)/@fun_Big_ProdSrv_TotalCost,9) 
				                ELSE round(ISNULL(prodSrvCostList.costAmt,0)/@fun_prodSrv_TotalCost,9)
				                END percentage
			        FROM ( SELECT a.prodSrvCode, a.isBigContract, a.costAmt
                           FROM #directProdSrvCost a
                           UNION
                           SELECT b.prodSrvCode, b.isBigContract, b.costAmt
                           FROM #composeProdSrvCost b
                          ) prodSrvCostList
		        --打开管理部门产品成本列表Cursor
		        OPEN fun_prod_srv_list
		        FETCH NEXT FROM fun_prod_srv_list INTO @prodSrvKey, @rate
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
			            --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				        INSERT INTO ODM.COST_A_PROD_DIV_LEVELONE(DEPT_CODE, PRD_SRV_KEY, PRD_ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                VALUES (@dept_id
						           ,@prodSrvKey
						           ,@prodEleCode
				                   ,@tailCountingAmount
						           ,@iyperiod)

						--将服务管理成本分摊到服务对应的产品上面 --按照产品工时占比

						SET @checkDigit = 0
						SELECT @checkDigit=COUNT(1)
						FROM COST_A_DEPT_SRV_FOR_PROD_MAP_T a
						WHERE a.IYPERIOD=@iyperiod and
						      a.SERVICE_KEY = @prodSrvKey
                        --如果存在需要向服务下的产品分摊管理产品，那么就进行分摊
						IF (@checkDigit IS NOT NULL AND 0 < @checkDigit)
						    BEGIN
							    DECLARE inner_dept_cursor CURSOR FOR
								    SELECT DISTINCT a.DEPT_CODE
									FROM COST_A_DEPT_SRV_FOR_PROD_MAP_T a
						            WHERE a.IYPERIOD=@iyperiod and
						                  a.SERVICE_KEY = @prodSrvKey
								OPEN inner_dept_cursor 
		                        FETCH NEXT FROM inner_dept_cursor INTO @inner_dept_code
						        WHILE @@FETCH_STATUS = 0
								    BEGIN
									    --开始将服务管理成本分摊到产品之上
                                        SET @inner_workingHours = 0
							            --取得服务总工时
							            SELECT @inner_workingHours=a.WORKING_VALUE
							            FROM COST_A_DEPT_SRV_FOR_PROD_MAP_T a
							            WHERE a.DEPT_CODE=@inner_dept_code and a.IYPERIOD=@iyperiod and
							                  a.SERVICE_KEY = @prodSrvKey and a.PRODUCT_KEY='0'
   
								        IF (@inner_workingHours IS NOT NULL AND @inner_workingHours <> 0)
								            BEGIN
								                SET @inner_tailCountingAmount = 0
                                                SET @inner_tailTotalAmount = 0
							                    SET @inner_total_tmp = 0
									            SET @inner_rate = 0
									        DECLARE inner_producs_hour_div_cursor CURSOR FOR
									            SELECT a.PRODUCT_KEY,  round(ISNULL(a.WORKING_VALUE,0)/@inner_workingHours,9)
										        FROM COST_A_DEPT_SRV_FOR_PROD_MAP_T a   
										        WHERE a.DEPT_CODE = @inner_dept_code and a.IYPERIOD = @iyperiod and
										              a.SERVICE_KEY = @prodSrvKey and a.PRODUCT_KEY <> '0'
		                                    OPEN inner_producs_hour_div_cursor 
		                                    FETCH NEXT FROM inner_producs_hour_div_cursor INTO @product_key, @inner_rate
									        WHILE @@FETCH_STATUS = 0 
									            BEGIN
										            --进行尾差处理(处理占比除不尽的情况)
			                                        IF (1- @inner_total_tmp <= @inner_rate)
			                                            BEGIN
					                                        SET @inner_tailCountingAmount = (@tailCountingAmount-@inner_tailTotalAmount)
			                                            END
				                                    ELSE 
				                                        BEGIN
					                                        SET @inner_tailCountingAmount=round(@tailCountingAmount*@inner_rate,10)
				                                    END       
			                                        --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				                                    INSERT INTO ODM.COST_A_PROD_MANAGE_COST_DIV(DEPT_CODE, SRV_CODE, PROD_CODE, ELE_CODE, AMOUNT, IYPERIOD)
			                                            VALUES (@inner_dept_code
						                                       ,@prodSrvKey
														       ,@product_key
						                                       ,@prodEleCode
				                                               ,@inner_tailCountingAmount
						                                       ,@iyperiod)

								   			        SET @inner_tailTotalAmount = @inner_tailTotalAmount + @inner_tailCountingAmount
	                                                SET @inner_total_tmp =  @inner_total_tmp + @inner_rate
											        --取得下一条数据
											        FETCH NEXT FROM inner_producs_hour_div_cursor INTO @product_key, @inner_rate
										        END
								            CLOSE inner_producs_hour_div_cursor
									        DEALLOCATE inner_producs_hour_div_cursor
								         END

									    FETCH NEXT FROM inner_dept_cursor INTO @inner_dept_code
									END

								CLOSE inner_dept_cursor
								DEALLOCATE inner_dept_cursor
							END
				        
						SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                    SET @total_tmp =  @total_tmp + @rate

			 	        FETCH NEXT FROM fun_prod_srv_list INTO @prodSrvKey, @rate
			         END
		        CLOSE fun_prod_srv_list
		        DEALLOCATE fun_prod_srv_list
			END
		--职能部门按照产品维度进行分摊--END

	    --进行一次分摊，按照活动维度进行分摊 --Start
		--取得只能部门活动总工时
	    SELECT @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))
	    FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
		WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.PROD_SRV_KEY='0'
		     and a.ACTIVITYORGROUP_TYPE='1'
        GROUP BY a.DEPT_CODE
		--只有总工时不为0的时候才开始分摊
		IF (@deptTotalWorkingHour IS NOT NULL AND @deptTotalWorkingHour <> 0)
		    BEGIN	 
			    --尾差参数初始化
			    SET @total_tmp=0
				SET @tailCountingAmount=0
				SET @tailTotalAmount=0

		        DECLARE func_activities_cursor CURSOR FOR
			        SELECT a.ACTIVITYORGROUP_CODE, '0' PROD_SRV_KEY, round(ISNULL(a.WORKTIME_VALUE,0)/@deptTotalWorkingHour,9) percentage
				    FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
				    WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod and a.PROD_SRV_KEY='0' and a.ACTIVITYORGROUP_TYPE='1'
				    --GROUP BY a.ACTIVITYORGROUP_CODE
			    OPEN func_activities_cursor
			    FETCH NEXT FROM func_activities_cursor INTO @func_activity_code,@prodSrvKey, @rate --循环处理每个产品/服务
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
						--将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中		    
				        INSERT INTO [ODM].[COST_A_ACTIVITY_COST](DEPT_CODE, ACTIVITY_KEY, PROD_SRV_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                VALUES (@dept_id
							       ,@func_activity_code
							       ,@prodSrvKey
							       ,@prodEleCode
				                   ,@tailCountingAmount
							       ,@iyperiod)

						SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                    SET @total_tmp =  @total_tmp + @rate
				        FETCH NEXT FROM func_activities_cursor INTO @func_activity_code,@prodSrvKey, @rate
				    END
			    CLOSE func_activities_cursor
			    DEALLOCATE func_activities_cursor
			END      	
		--活动维度一次分摊---End
	    
		FETCH NEXT FROM func_dept_ele_cost_cursor INTO @dept_id, @prodEleCode, @iyperiod, @cur_amount
	END
CLOSE func_dept_ele_cost_cursor
DEALLOCATE func_dept_ele_cost_cursor

DROP TABLE #directProdSrvCost
DROP TABLE #composeProdSrvCost


--进行其他部门的活动工时分摊
--对测试部进行活动成本分摊
SET @dept_id = '204'
IF (@iyperiod IS NULL OR @iyperiod = '')
    BEGIN
	    SET @iyperiod = @max_iyperiod
	END
DECLARE test_dept_services_cursor CURSOR FOR
    SELECT DISTINCT a.PRD_SRV_KEY
    FROM ODM.COST_A_PROD_DIV_LEVELONE a
    WHERE a.DEPT_CODE = @dept_id and a.IYPERIOD=@iyperiod

OPEN test_dept_services_cursor
FETCH NEXT FROM test_dept_services_cursor INTO @prodSrvKey --循环处理每个产品/服务
WHILE @@FETCH_STATUS = 0
    BEGIN
	    --取得该服务下的活动总工时
		SET @deptTotalWorkingHour = 0
		SELECT @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))
		FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
		WHERE a.ACTIVITYORGROUP_TYPE='1' and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and
		      a.PROD_SRV_KEY=@prodSrvKey

        IF (@deptTotalWorkingHour IS NOT NULL AND @deptTotalWorkingHour<>0)
		    BEGIN
			    --循环处理每个服务下的成本元素
		        DECLARE test_srv_cost_ele_cursor CURSOR FOR
			        SELECT a.PRD_ELE_CODE, a.CUR_AMOUNT
				    FROM ODM.COST_A_PROD_DIV_LEVELONE a
				    WHERE a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and a.PRD_SRV_KEY=@prodSrvKey
			    OPEN test_srv_cost_ele_cursor
			    FETCH NEXT FROM test_srv_cost_ele_cursor INTO @prodEleCode, @cur_amount
			    WHILE @@FETCH_STATUS = 0
				    BEGIN
				        --尾差参数初始化
			            SET @total_tmp=0
				        SET @tailCountingAmount=0
				        SET @tailTotalAmount=0
						IF (@cur_amount IS NOT NULL AND @cur_amount != 0)
						    BEGIN
							    --循环处理该服务下面的活动
								DECLARE srv_activity_hour_cursor CURSOR FOR
								    SELECT a.ACTIVITYORGROUP_CODE, round(ISNULL(a.WORKTIME_VALUE,0)/@deptTotalWorkingHour,9) percentage
								    FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a
									WHERE a.ACTIVITYORGROUP_TYPE='1' and a.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and
		                                  a.PROD_SRV_KEY=@prodSrvKey
								OPEN srv_activity_hour_cursor
								FETCH NEXT FROM srv_activity_hour_cursor INTO @func_activity_code, @rate
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
				                        INSERT INTO [ODM].[COST_A_ACTIVITY_COST](DEPT_CODE, ACTIVITY_KEY, PROD_SRV_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                VALUES (@dept_id
							                       ,@func_activity_code
							                       ,@prodSrvKey
							                       ,@prodEleCode
				                                   ,@tailCountingAmount
							                       ,@iyperiod)

						                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                    SET @total_tmp =  @total_tmp + @rate

									    FETCH NEXT FROM srv_activity_hour_cursor INTO @func_activity_code, @rate
									END
								CLOSE srv_activity_hour_cursor
								DEALLOCATE srv_activity_hour_cursor
							END
					    FETCH NEXT FROM test_srv_cost_ele_cursor INTO @prodEleCode, @cur_amount
			        END
                CLOSE test_srv_cost_ele_cursor
			    DEALLOCATE test_srv_cost_ele_cursor
	        END

	    FETCH NEXT FROM test_dept_services_cursor INTO @prodSrvKey
	END

CLOSE test_dept_services_cursor
DEALLOCATE test_dept_services_cursor


--对其他需要进行活动成本分摊的部门进行分摊
--初始化SERVICE KEY
SET @prodSrvKey = '0'
IF (@iyperiod IS NULL OR @iyperiod = '')
    BEGIN
	    SET @iyperiod = @max_iyperiod
	END
DECLARE div_activity_dept_cursor CURSOR FOR
    SELECT DISTINCT DEPT_CODE
	FROM ODM.COST_A_ACTIVITY_DIV_DEPT_MAP
OPEN div_activity_dept_cursor
FETCH NEXT FROM div_activity_dept_cursor INTO @dept_id  --循环处理需要活动分摊的部门
WHILE @@FETCH_STATUS = 0
    BEGIN	   
	    --取得该部门的活动总工时
        SELECT @deptTotalWorkingHour=CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))
        FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a,
		     ODM.COST_A_ACTIVITY_DIV_DEPT_MAP b
	    WHERE b.SOURCE_DEPT_CODE = a.DEPT_CODE and b.DEPT_CODE=@dept_id and
              a.ACTIVITYORGROUP_TYPE='1' and a.IYPERIOD=@iyperiod and
              a.PROD_SRV_KEY='0'	

		IF (@deptTotalWorkingHour IS NOT NULl AND @deptTotalWorkingHour<>0)
		    BEGIN
			    DECLARE div_dept_ele_cursor CURSOR FOR
                    SELECT b.DEPT_CODE, a.PRD_ELE_CODE, CAST(SUM(ISNULL(a.CUR_AMOUNT,0)) AS DECIMAL(28,10)) ELE_AMOUNT
                    FROM ODM.COST_A_PROD_DIV_LEVELONE a,
			             ODM.COST_A_ACTIVITY_DIV_DEPT_MAP b
                    WHERE a.DEPT_CODE = b.SOURCE_DEPT_CODE and a.IYPERIOD=@iyperiod and b.DEPT_CODE=@dept_id
                    GROUP BY b.DEPT_CODE, a.PRD_ELE_CODE
                OPEN div_dept_ele_cursor
                FETCH NEXT FROM div_dept_ele_cursor INTO @dept_id,  @prodEleCode, @cur_amount--循环处理成本元素
                WHILE @@FETCH_STATUS = 0
		            BEGIN
		                IF (@cur_amount IS NOT NULL AND @cur_amount <> 0)
				            BEGIN
					            --尾差参数初始
		                        SET @total_tmp=0
		                        SET @tailCountingAmount=0
		                        SET @tailTotalAmount=0

						        DECLARE dev_activity_hour_cursor CURSOR FOR
		                            SELECT a.ACTIVITYORGROUP_CODE,  ROUND(CAST(SUM(ISNULL(a.WORKTIME_VALUE,0)) AS DECIMAL(28,10))/@deptTotalWorkingHour,9) percentage
			                        FROM ODM.COST_A_ACTIORGRO_PROORSER_MAP_T a,
							             ODM.COST_A_ACTIVITY_DIV_DEPT_MAP b
                                    WHERE a.DEPT_CODE=b.SOURCE_DEPT_CODE and a.ACTIVITYORGROUP_TYPE='1' and b.DEPT_CODE=@dept_id and a.IYPERIOD=@iyperiod and
                                          a.PROD_SRV_KEY='0'
					                GROUP BY a.ACTIVITYORGROUP_CODE
				                OPEN dev_activity_hour_cursor
				                FETCH NEXT FROM dev_activity_hour_cursor INTO @func_activity_code, @rate--循环处理成本元素
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
	                                    --将部门下每个产品/服务占用成本元素的成本插入COST_A_PROD_DIV_LEVELONE 表中	
			                            INSERT INTO [ODM].[COST_A_ACTIVITY_COST](DEPT_CODE, ACTIVITY_KEY, PROD_SRV_KEY, ELE_CODE, CUR_AMOUNT, IYPERIOD)
			                                VALUES (@dept_id
							                       ,@func_activity_code
							                       ,@prodSrvKey
							                       ,@prodEleCode
				                                   ,@tailCountingAmount
							                       ,@iyperiod)

						                SET @tailTotalAmount = @tailTotalAmount + @tailCountingAmount
	                                    SET @total_tmp =  @total_tmp + @rate
					                    FETCH NEXT FROM dev_activity_hour_cursor INTO @func_activity_code, @rate--循环活动工时
					                END
                                CLOSE dev_activity_hour_cursor
				                DEALLOCATE dev_activity_hour_cursor
					        END
			            FETCH NEXT FROM div_dept_ele_cursor INTO @dept_id,  @prodEleCode, @cur_amount--循环处理成本元素
			        END 
                CLOSE div_dept_ele_cursor
		        DEALLOCATE div_dept_ele_cursor
			END
		    FETCH NEXT FROM div_activity_dept_cursor INTO @dept_id  --循环处理需要活动分摊的部门
	END
CLOSE div_activity_dept_cursor
DEALLOCATE div_activity_dept_cursor


--产品占用资产分摊
IF (@iyperiod IS NULL OR @iyperiod = '')
    BEGIN
	    SET @iyperiod = @max_iyperiod
	END
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

	    --分摊共用软件
		SET @cur_amount=0
        SELECT @cur_amount=CAST(SUM(ISNULL(DBLDEPR,0)) AS DECIMAL(28,10))
        FROM ODM.FUN_GETASSETS(2, 1, '0', @iyperiod)

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
		                           ,1
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

DECLARE @flex_code1 VARCHAR(20)
DECLARE @flex_rate1 decimal(28,10)
DECLARE @flex_code2 VARCHAR(20)
DECLARE @flex_rate2 decimal(28,10)
DECLARE @flex_code3 VARCHAR(20)
DECLARE @flex_rate3 decimal(28,10)
DECLARE @assetNum VARCHAR(20)

--第二步分摊部分占用
TRUNCATE TABLE ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP

--硬件部分占用
DECLARE partial_share_assets_cursor CURSOR FOR
    SELECT a.DBLDEPR, a.FLEX_OCCUPY_CODE1, a.OCCUPY_PERCENTAGE1, a.FLEX_OCCUPY_CODE2, a.OCCUPY_PERCENTAGE2,
           a.FLEX_OCCUPY_CODE3, a.OCCUPY_PERCENTAGE3, a.SASSETNUM
    FROM ODM.FUN_GETASSETS(2, 0, '-1', @iyperiod) a
OPEN partial_share_assets_cursor
FETCH NEXT FROM partial_share_assets_cursor INTO @cur_amount, @flex_code1, @flex_rate1, @flex_code2
                                                ,@flex_rate2, @flex_code3, @flex_rate3, @assetNum --循环处理运维工时占比
WHILE @@FETCH_STATUS = 0
    BEGIN
	    IF (@cur_amount IS NOT NULL AND @cur_amount <> 0)
		    BEGIN
			    --处理第一个占用比例
			    IF (@flex_code1 IS NOT NULL AND @flex_code1 <> '' AND @flex_rate1 IS NOT NULL AND @flex_rate1 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code1, @cur_amount*@flex_rate1)
					END
				--处理第二个占用比例
			    IF (@flex_code2 IS NOT NULL AND @flex_code2 <> '' AND @flex_rate2 IS NOT NULL AND @flex_rate2 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code2, @cur_amount*@flex_rate2)
					END
				 --处理第三个占用比例
			    IF (@flex_code3 IS NOT NULL AND @flex_code3 <> '' AND @flex_rate3 IS NOT NULL AND @flex_rate3 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code3, @cur_amount*@flex_rate3)
					END
			END
		FETCH NEXT FROM partial_share_assets_cursor INTO @cur_amount, @flex_code1, @flex_rate1, @flex_code2
                                                ,@flex_rate2, @flex_code3, @flex_rate3, @assetNum --循环处理运维工时占比
	END
CLOSE partial_share_assets_cursor
DEALLOCATE partial_share_assets_cursor

--将部分共用硬件出入占用表
INSERT INTO [ODM].COST_A_PROD_OCCUPY_ASSETS(PROD_CODE, ASSET_TYPE, SHARE_TYP, AMOUNT,IYPERIOD)
    SELECT a.PROD_CODE, 0, -1, CAST(SUM(ISNULL(a.AMOUNT, 0)) AS DECIMAL(28,10)), @iyperiod
	FROM ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP a
	GROUP BY a.PROD_CODE


--软件部分占用
TRUNCATE TABLE ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP
DECLARE partial_share_assets_cursor CURSOR FOR
    SELECT a.DBLDEPR, a.FLEX_OCCUPY_CODE1, a.OCCUPY_PERCENTAGE1, a.FLEX_OCCUPY_CODE2, a.OCCUPY_PERCENTAGE2,
           a.FLEX_OCCUPY_CODE3, a.OCCUPY_PERCENTAGE3, a.SASSETNUM
    FROM ODM.FUN_GETASSETS(2, 1, '-1', @iyperiod) a
OPEN partial_share_assets_cursor
FETCH NEXT FROM partial_share_assets_cursor INTO @cur_amount, @flex_code1, @flex_rate1, @flex_code2
                                                ,@flex_rate2, @flex_code3, @flex_rate3, @assetNum --循环处理运维工时占比
WHILE @@FETCH_STATUS = 0
    BEGIN
	    IF (@cur_amount IS NOT NULL AND @cur_amount <> 0)
		    BEGIN
			    --处理第一个占用比例
			    IF (@flex_code1 IS NOT NULL AND @flex_code1 <> '' AND @flex_rate1 IS NOT NULL AND @flex_rate1 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code1, @cur_amount*@flex_rate1)
					END
				--处理第二个占用比例
			    IF (@flex_code2 IS NOT NULL AND @flex_code2 <> '' AND @flex_rate2 IS NOT NULL AND @flex_rate2 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code2, @cur_amount*@flex_rate2)
					END
				 --处理第三个占用比例
			    IF (@flex_code3 IS NOT NULL AND @flex_code3 <> '' AND @flex_rate3 IS NOT NULL AND @flex_rate3 <> 0)
				    BEGIN
					    INSERT INTO ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP(PROD_CODE, AMOUNT)
						    VALUES(@flex_code3, @cur_amount*@flex_rate3)
					END
			END
		FETCH NEXT FROM partial_share_assets_cursor INTO @cur_amount, @flex_code1, @flex_rate1, @flex_code2
                                                ,@flex_rate2, @flex_code3, @flex_rate3, @assetNum --循环处理运维工时占比
	END
CLOSE partial_share_assets_cursor
DEALLOCATE partial_share_assets_cursor

--将部分共用软件插入占用表
INSERT INTO [ODM].COST_A_PROD_OCCUPY_ASSETS(PROD_CODE, ASSET_TYPE, SHARE_TYP, AMOUNT,IYPERIOD)
    SELECT a.PROD_CODE, 1, -1, CAST(SUM(ISNULL(a.AMOUNT, 0)) AS DECIMAL(28,10)), @iyperiod
	FROM ODM.COST_A_PARTIAL_SHARE_ASSETS_TMP a
	GROUP BY a.PROD_CODE


--处理非共用硬件
INSERT INTO [ODM].COST_A_PROD_OCCUPY_ASSETS(PROD_CODE, ASSET_TYPE, SHARE_TYP, AMOUNT,IYPERIOD)
    SELECT a.ASSET_OCCUPY_CODE, 0, 1, CAST(SUM(ISNULL(a.DBLDEPR, 0)) AS DECIMAL(28,10)), @iyperiod
	FROM ODM.FUN_GETASSETS(2, 0, 'all', @iyperiod) a
	WHERE a.ASSET_OCCUPY_CODE NOT IN ('0', '-1')
	GROUP BY a.ASSET_OCCUPY_CODE

--处理非共用软件
INSERT INTO [ODM].COST_A_PROD_OCCUPY_ASSETS(PROD_CODE, ASSET_TYPE, SHARE_TYP, AMOUNT,IYPERIOD)
    SELECT a.ASSET_OCCUPY_CODE, 1, 1, CAST(SUM(ISNULL(a.DBLDEPR, 0)) AS DECIMAL(28,10)), @iyperiod
	FROM ODM.FUN_GETASSETS(2, 1, 'all', @iyperiod) a
	WHERE a.ASSET_OCCUPY_CODE NOT IN ('0', '-1')
	GROUP BY a.ASSET_OCCUPY_CODE







