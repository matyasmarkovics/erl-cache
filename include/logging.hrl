%%============================================================================
%% Logging convenience functions
%%============================================================================

%% error_logger does not support debug logging, so squelch it.
% -define(DEBUG(Msg, Args), _ = error_logger:info_msg(Msg, Args)).
-define(DEBUG(_Msg, _Args), ok).
-define(INFO(Msg, Args), _ = error_logger:info_msg(Msg, Args)).
-define(NOTICE(Msg, Args), _ = error_logger:warning_msg(Msg, Args)).
-define(WARNING(Msg, Args), _ = error_logger:warning_msg(Msg, Args)).
-define(ERROR(Msg, Args), _ = error_logger:error_msg(Msg, Args)).
