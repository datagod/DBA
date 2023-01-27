drop function fn_SecondsToTime

go
create function fn_SecondsToTime
(
  @seconds int
)
returns varchar(8)
as
begin
  declare @TheTime time,
          @CharTime varchar(8)

  select @CharTime = convert(varchar(8), dateadd(ms, (@seconds % 86400 ) * 1000, 0), 114)
  return @CharTime
end
go


