//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|  模块职责：日志与通知模块 —— 分级日志（INFO/WARN/ERROR）写文件 +   |
//|            Print 输出；关键事件手机推送/邮件；同类 WARN 去重节流    |
//|  对应方案文档：第 3.2 节（CLogger）、6.5 节（日志去重）、8.3 节     |
//+------------------------------------------------------------------+
#ifndef __GREA_LOGGER_MQH__
#define __GREA_LOGGER_MQH__

#include <GoldRangeEA/Config.mqh>

//--- 单日日志容量告警阈值 50MB（修复四）
#define GREA_LOG_MAX_BYTES  (50 * 1024 * 1024)

//--- C6：WARN 节流表 key 数量上限（防御性，key 种类理论上有限）
#define GREA_THROTTLE_MAX_KEYS  100

//--- 日志级别
enum ENUM_LOG_LEVEL
  {
   LOG_LEVEL_INFO  = 0,
   LOG_LEVEL_WARN  = 1,
   LOG_LEVEL_ERROR = 2
  };

//+------------------------------------------------------------------+
//| CLogger：分级日志与通知                                            |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   long              m_magic;             // 魔术号（日志标签）
   string            m_dir;               // 日志目录 Files/GoldRangeEA/
   // WARN 节流表：同一 key 在 throttleSec 内只记一次（方案 6.5，防日志刷屏）
   string            m_throttleKeys[];
   datetime          m_throttleTimes[];
   // 修复四：容量与保留策略相关状态
   string            m_currentLogName;    // 当前日志文件名（跨日切换检测）
   bool              m_sizeWarned;        // 单日文件超阈值只告警一次
   bool              m_openFailAlerted;   // FileOpen 失败只推送告警一次

   //--- 写一行日志到当日文件（Files/GoldRangeEA/yyyymmdd.log）并 Print
   void              WriteLine(const ENUM_LOG_LEVEL level, const string msg)
     {
      static string levels[3] = {"INFO ", "WARN ", "ERROR"};
      string line = StringFormat("%s [%s] [magic=%I64d] %s",
                                 TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                                 levels[(int)level], m_magic, msg);
      Print(line);
      // 优化模式（评审修复 F5）：只 Print 不写文件——优化遍历数以千计
      // 逐条开/写/关文件严重拖慢优化；单遍回测（MQL_TESTER 非优化）与
      // 实盘保持现状写文件
      if(MQLInfoInteger(MQL_OPTIMIZATION))
         return;
      // 修复四：跨日切换日志文件时清理超期旧日志，并复位单日容量告警标记
      string today = FileNameOfToday();
      if(today != m_currentLogName)
        {
         m_currentLogName = today;
         m_sizeWarned     = false;
         CleanupOldLogs();
        }
      // 按日期滚动的日志文件：追加写入 Files/GoldRangeEA/yyyymmdd.log
      // （评审修复 F9：日志按 UTF-8 编码落盘，中文日志在英文系统上不再
      //  乱码。注意 MQL5 并无 FILE_UTF8 标志，UTF-8 须以二进制模式手工
      //  编码：StringToCharArray(CP_UTF8) 转字节流后 FileWriteArray 写入）
      int h = FileOpen(m_dir + today, FILE_READ|FILE_WRITE|FILE_BIN);
      if(h == INVALID_HANDLE)
        {
         // 修复四：打开失败除 Print 外推送告警（仅一次，先置位防递归）
         Print("[Logger] 日志文件打开失败, err=", GetLastError());
         if(!m_openFailAlerted)
           {
            m_openFailAlerted = true;
            Notify("日志文件打开失败, 日志仅输出到终端, 请检查磁盘/权限");
           }
         return;
        }
      FileSeek(h, 0, SEEK_END);
      // 当日首条（文件为空）先写 UTF-8 BOM，编辑器可自动识别编码
      if(FileTell(h) == 0)
        {
         uchar bom[] = {0xEF, 0xBB, 0xBF};
         FileWriteArray(h, bom, 0, ArraySize(bom));
        }
      // StringToCharArray 返回字节数含结尾 '\0'，写 n-1 剔除终止符
      uchar utf8[];
      int n = StringToCharArray(line + "\r\n", utf8, 0, WHOLE_ARRAY, CP_UTF8);
      if(n > 1)
         FileWriteArray(h, utf8, 0, n - 1);
      long fsize = FileSize(h);
      FileClose(h);
      // 修复四：单日文件超过阈值写一条 WARN（先置位防递归，只提示一次）
      if(!m_sizeWarned && fsize > GREA_LOG_MAX_BYTES)
        {
         m_sizeWarned = true;
         Warn(StringFormat("当日日志文件已超 %d MB, 请检查是否存在告警刷屏",
                           GREA_LOG_MAX_BYTES / 1024 / 1024));
        }
     }

   //--- 生成当日日志文件名 yyyymmdd.log
   string            FileNameOfToday()
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return StringFormat("%04d%02d%02d.log", dt.year, dt.mon, dt.day);
     }

   //--- 修复四：清理超过 InpLogKeepDays 保留天数的旧日志文件
   //    注意：本函数只用 Print 输出，不走 WriteLine，避免递归
   void              CleanupOldLogs()
     {
      string name;
      long find = FileFindFirst(m_dir + "*.log", name);
      if(find == INVALID_HANDLE)
         return;
      // 至少保留 1 天（评审修复 F9）：InpLogKeepDays=0 时防 cutoff=当前
      // 时刻而误删当日日志
      datetime cutoff = TimeCurrent() - (datetime)MathMax(InpLogKeepDays, 1) * 86400;
      do
        {
         // 文件名形如 yyyymmdd.log（长度12），解析为日期后判断是否超期
         if(StringLen(name) == 12)
           {
            datetime t = StringToTime(StringSubstr(name, 0, 4) + "." +
                                      StringSubstr(name, 4, 2) + "." +
                                      StringSubstr(name, 6, 2));
            if(t > 0 && t < cutoff)
              {
               if(FileDelete(m_dir + name))
                  Print("[Logger] 已清理超期日志: ", name);
              }
           }
        }
      while(FileFindNext(find, name));
      FileFindClose(find);
     }

public:
                     CLogger() : m_magic(0), m_dir("GoldRangeEA\\"),
                                 m_currentLogName(""), m_sizeWarned(false),
                                 m_openFailAlerted(false) {}
                    ~CLogger() {}

   //--- 初始化：记录魔术号、创建日志目录；返回 true=成功
   bool              Init(const long magic)
     {
      m_magic = magic;
      // FolderCreate 在 MQL5\Files 沙箱下创建目录，已存在则返回 false 但 GetLastError=0
      ResetLastError();
      FolderCreate("GoldRangeEA");
      // 修复四：Init 时即清理一次超期旧日志
      m_currentLogName = FileNameOfToday();
      CleanupOldLogs();
      Info("Logger 初始化完成");
      return true;
     }

   //--- INFO 级：常规流程记录（信号评估、状态流转等）
   void              Info(const string msg)  { WriteLine(LOG_LEVEL_INFO, msg); }

   //--- WARN 级：非致命异常（点差过大、数据不足、过滤原因等）
   void              Warn(const string msg)  { WriteLine(LOG_LEVEL_WARN, msg); }

   //--- ERROR 级：致命/需人工关注（下单失败重试耗尽、句柄失效等）
   void              Error(const string msg) { WriteLine(LOG_LEVEL_ERROR, msg); }

   //--- 节流版 WARN：同一 key 在 throttleSec（默认300s）内只记录一次
   //    用途：每 Tick 环境校验失败等高频同因告警（方案 6.5）
   void              WarnThrottled(const string key, const string msg, const int throttleSec = 300)
     {
      datetime now = TimeCurrent();
      int n = ArraySize(m_throttleKeys);
      for(int i = 0; i < n; i++)
        {
         if(m_throttleKeys[i] == key)
           {
            if(now - m_throttleTimes[i] < throttleSec)
               return;                      // 节流窗口内，跳过
            m_throttleTimes[i] = now;
            Warn(msg);
            return;
           }
        }
      // 新 key：登记并记录
      // C6：节流表容量上限防御 —— 若 key 异常膨胀（如误将动态内容拼入
      //     key）则不再扩容，改为复用最旧槽位（LRU 淘汰），避免数组无限
      //     增长；代价仅是被淘汰 key 下次出现时多记一条 WARN，可接受
      if(n >= GREA_THROTTLE_MAX_KEYS)
        {
         int oldest = 0;
         for(int i = 1; i < n; i++)
            if(m_throttleTimes[i] < m_throttleTimes[oldest])
               oldest = i;
         m_throttleKeys[oldest]  = key;
         m_throttleTimes[oldest] = now;
         Warn(msg);
         return;
        }
      ArrayResize(m_throttleKeys, n + 1);
      ArrayResize(m_throttleTimes, n + 1);
      m_throttleKeys[n]  = key;
      m_throttleTimes[n] = now;
      Warn(msg);
     }

   //--- 关键事件通知：手机推送（测试器中自动跳过，方案 6.6）
   //    push=true 走 SendNotification（需终端配置 MetaQuotes ID）
   void              Notify(const string msg, const bool push = true)
     {
      Info("[NOTIFY] " + msg);
      if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
         return;                            // 测试器/优化中不可用，直接跳过
      if(push)
        {
         if(!SendNotification("[GoldRangeEA] " + msg))
            Warn("SendNotification 发送失败, err=" + (string)GetLastError());
        }
      // TODO(P2, 方案 8.3)：可选 SendMail 邮件通道、每日日报汇总
     }
  };

#endif // __GREA_LOGGER_MQH__
