%%============================================================================
%% Logging convenience functions
%%============================================================================

-define(DEBUG(Msg, Args), _ = error_logger:info_msg(Msg, Args)).
-define(INFO(Msg, Args), _ = error_logger:info_msg(Msg, Args)).
-define(NOTICE(Msg, Args), _ = error_logger:warning_msg(Msg, Args)).
-define(WARNING(Msg, Args), _ = error_logger:warning_msg(Msg, Args)).
-define(ERROR(Msg, Args), _ = error_logger:error_msg(Msg, Args)).


