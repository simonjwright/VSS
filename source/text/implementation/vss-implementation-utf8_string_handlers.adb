------------------------------------------------------------------------------
--                        M A G I C   R U N T I M E                         --
--                                                                          --
--                       Copyright (C) 2020, AdaCore                        --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------
--  Generic implementation of the string which use UTF-8 encoding for data.

with Ada.Unchecked_Deallocation;

with VSS.Implementation.String_Configuration;

package body VSS.Implementation.UTF8_String_Handlers is

   use type VSS.Implementation.Strings.Character_Count;
   use type VSS.Unicode.UTF8_Code_Unit_Count;

   Line_Feed              : constant VSS.Unicode.Code_Point := 16#00_000A#;
   Line_Tabulation        : constant VSS.Unicode.Code_Point := 16#00_000B#;
   Form_Feed              : constant VSS.Unicode.Code_Point := 16#00_000C#;
   Carriage_Return        : constant VSS.Unicode.Code_Point := 16#00_000D#;
   Next_Line              : constant VSS.Unicode.Code_Point := 16#00_0085#;
   Line_Separator         : constant VSS.Unicode.Code_Point := 16#00_2028#;
   Paragraph_Separator    : constant VSS.Unicode.Code_Point := 16#00_2029#;

   type Verification_State is
     (Initial,    --  ASCII or start of multibyte sequence
      U31,        --  A0 .. BF | UT1
      U33,        --  80 .. 9F | UT1
      U41,        --  90 .. BF | UT2
      U43,        --  80 .. 8F | UT2
      UT1,        --  1 (80 .. BF)
      UT2,        --  2 (80 .. BF)
      UT3,        --  3 (80 .. BF)
      Ill_Formed);
   --  Unicode defines well-formed UTF-8 as
   --
   --  00 .. 7F
   --  C2 .. DF | 80 .. BF
   --  E0       | A0 .. BF | 80 .. BF
   --  E1 .. EC | 80 .. BF | 80 .. BF
   --  ED       | 80 .. 9F | 80 .. BF
   --  EE .. EF | 80 .. BF | 80 .. BF
   --  F0       | 90 .. BF | 80 .. BF | 80 .. BF
   --  F1 .. F3 | 80 .. BF | 80 .. BF | 80 .. BF
   --  F4       | 80 .. 8F | 80 .. BF | 80 .. BF

   function Unchecked_Decode
     (Storage : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Offset  : VSS.Unicode.UTF8_Code_Unit_Index)
      return VSS.Unicode.Code_Point;
   --  Decode UTF8 encoded character started at given offset

   procedure Unchecked_Forward
     (Storage  : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Position : in out VSS.Implementation.Strings.Cursor);
   --  Move cursor to position of the next character
   procedure Unchecked_Backward
     (Storage  : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Position : in out VSS.Implementation.Strings.Cursor);
   --  Move cursor to position of the previous character

   procedure Validate_And_Copy
     (Source      : Ada.Strings.UTF_Encoding.UTF_8_String;
      Destination : out VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Length      : out VSS.Implementation.Strings.Character_Count;
      Success     : out Boolean);
   --  Validate UTF-8 encoding and copy validated part of the data to
   --  Destination. Length is set to the length of the text in characters.
   --  Success is set False when validation is failed and to True otherwise.

   Growth_Factor            : constant := 32;
   --  The growth factor controls how much extra space is allocated when
   --  we have to increase the size of an allocated unbounded string. By
   --  allocating extra space, we avoid the need to reallocate on every
   --  append, particularly important when a string is built up by repeated
   --  append operations of small pieces. This is expressed as a factor so
   --  32 means add 1/32 of the length of the string as growth space.

   Minimal_Allocation_Block : constant := Standard'Maximum_Alignment;
   --  Allocation will be done by a multiple of Minimal_Allocation_Block.
   --  This causes no memory loss as most (all?) malloc implementations are
   --  obliged to align the returned memory on the maximum alignment as malloc
   --  does not know the target alignment.

   function Aligned_Capacity
     (Capacity : VSS.Unicode.UTF8_Code_Unit_Count)
      return VSS.Unicode.UTF8_Code_Unit_Count;
   --  Returns recommended capacity of the string data storage which is greater
   --  or equal to the specified requested capacity. Calculation take in sense
   --  alignment of the allocated memory segments to use memory effectively by
   --  sequential operations which extends size of the buffer.

   function Allocate
     (Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count)
      return UTF8_String_Data_Access;
   --  Allocate storage block to store at least given amount of the data.

   procedure Reallocate
     (Data     : in out UTF8_String_Data_Access;
      Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count);
   --  Reallocates storage block to store at least given amount of the data.
   --  Content of the data will be copied, and old storage block will be
   --  unreferenced (and deallocated if it is no longer used).

   procedure Unreference (Data : in out UTF8_String_Data_Access);
   --  Decrement reference counter and deallocate storage block when reference
   --  counter reach zero.

   procedure Mutate
     (Data     : in out UTF8_String_Data_Access;
      Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count);
   --  Reallocate storage block when it is shared or not enough to store given
   --  amount of data.

   procedure Split_Lines_Common
     (Handler         :
        VSS.Implementation.String_Handlers.Abstract_String_Handler'Class;
      Data            : VSS.Implementation.Strings.String_Data;
      Storage         : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Terminators     : VSS.Strings.Line_Terminator_Set;
      Keep_Terminator : Boolean;
      Lines           : in out
        VSS.Implementation.String_Vectors.String_Vector_Data_Access);
   --  Common code of Split_Lines subprogram for on heap and inline handlers.

   --------------------------
   -- After_Last_Character --
   --------------------------

   overriding procedure After_Last_Character
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor)
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;
   begin
      --  Go to the last character
      Position :=
        (Index        => Source.Length,
         UTF8_Offset  => Source.Size,
         UTF16_Offset => 0);

      if Source.Length > 0 then  --  Move beyond the end
         Unchecked_Forward (Source.Storage, Position);
      end if;

      --  FIXME :
      Position.UTF16_Offset := VSS.Unicode.UTF16_Code_Unit_Index'Last;
   end After_Last_Character;

   --------------------------
   -- After_Last_Character --
   --------------------------

   overriding procedure After_Last_Character
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor)
   is
      Source : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;
   begin
      --  Go to the last character
      Position :=
        (Index        => Strings.Character_Count (Source.Length),
         UTF8_Offset  => VSS.Unicode.UTF8_Code_Unit_Index (Source.Size),
         UTF16_Offset => 0);

      if Position.Index > 0 then  --  Move beyond the end
         Unchecked_Forward (Source.Storage, Position);
      end if;

      --  FIXME :
      Position.UTF16_Offset := VSS.Unicode.UTF16_Code_Unit_Index'Last;
   end After_Last_Character;

   ----------------------
   -- Aligned_Capacity --
   ----------------------

   function Aligned_Capacity
     (Capacity : VSS.Unicode.UTF8_Code_Unit_Count)
      return VSS.Unicode.UTF8_Code_Unit_Count
   is
      subtype Empty_UTF8_String_Data is UTF8_String_Data (0);

      Static_Size : constant VSS.Unicode.UTF8_Code_Unit_Count :=
        Empty_UTF8_String_Data'Max_Size_In_Storage_Elements;

   begin
      return
        ((Static_Size + Capacity) / Minimal_Allocation_Block + 1)
          * Minimal_Allocation_Block - Static_Size;
   end Aligned_Capacity;

   --------------
   -- Allocate --
   --------------

   function Allocate
     (Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count)
      return UTF8_String_Data_Access is
   begin
      return
        new UTF8_String_Data
              (Aligned_Capacity
                 (VSS.Unicode.UTF8_Code_Unit_Count'Max (Capacity, Size)));
   end Allocate;

   ------------
   -- Mutate --
   ------------

   procedure Mutate
     (Data     : in out UTF8_String_Data_Access;
      Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count) is
   begin
      if Data = null then
         Data := Allocate (Capacity, Size);

      elsif not System.Atomic_Counters.Is_One (Data.Counter)
        or else Size > Data.Bulk
      then
         Reallocate (Data, Capacity, Size);
      end if;
   end Mutate;

   ------------
   -- Append --
   ------------

   overriding procedure Append
     (Self : UTF8_String_Handler;
      Data : in out VSS.Implementation.Strings.String_Data;
      Code : VSS.Unicode.Code_Point)
   is
      Destination : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;
      L           : VSS.Implementation.UTF8_Encoding.UTF8_Sequence_Length;
      U1          : VSS.Unicode.UTF8_Code_Unit;
      U2          : VSS.Unicode.UTF8_Code_Unit;
      U3          : VSS.Unicode.UTF8_Code_Unit;
      U4          : VSS.Unicode.UTF8_Code_Unit;

   begin
      VSS.Implementation.UTF8_Encoding.Encode (Code, L, U1, U2, U3, U4);

      Mutate
        (Destination,
         VSS.Unicode.UTF8_Code_Unit_Count (Data.Capacity) * 4,
         (if Destination = null then 0 else Destination.Size) + L);

      Destination.Storage (Destination.Size) := U1;

      if L >= 2 then
         Destination.Storage (Destination.Size + 1) := U2;

         if L >= 3 then
            Destination.Storage (Destination.Size + 2) := U3;

            if L = 4 then
               Destination.Storage (Destination.Size + 3) := U4;
            end if;
         end if;
      end if;

      Destination.Size := Destination.Size + L;
      Destination.Length := Destination.Length + 1;
      Destination.Storage (Destination.Size) := 16#00#;
   end Append;

   ------------
   -- Append --
   ------------

   overriding procedure Append
     (Self : UTF8_In_Place_String_Handler;
      Data : in out VSS.Implementation.Strings.String_Data;
      Code : VSS.Unicode.Code_Point)
   is
      use type Interfaces.Unsigned_8;

      Destination : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;
      L           : VSS.Implementation.UTF8_Encoding.UTF8_Sequence_Length;
      U1          : VSS.Unicode.UTF8_Code_Unit;
      U2          : VSS.Unicode.UTF8_Code_Unit;
      U3          : VSS.Unicode.UTF8_Code_Unit;
      U4          : VSS.Unicode.UTF8_Code_Unit;

   begin
      VSS.Implementation.UTF8_Encoding.Encode (Code, L, U1, U2, U3, U4);

      if Destination.Size + Interfaces.Unsigned_8 (L)
           < Destination.Storage'Length
      then
         --  There are enough space to store data in place.

         Destination.Storage
           (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)) := U1;

         if L >= 2 then
            Destination.Storage
              (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size) + 1) := U2;

            if L >= 3 then
               Destination.Storage
                 (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size) + 2) :=
                   U3;

               if L = 4 then
                  Destination.Storage
                    (VSS.Unicode.UTF8_Code_Unit_Count
                       (Destination.Size + 3)) := U4;
               end if;
            end if;
         end if;

         Destination.Size := Destination.Size + Interfaces.Unsigned_8 (L);
         Destination.Length := Destination.Length + 1;
         Destination.Storage
           (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)) := 16#00#;

      else
         --  Data can't be stored "in place" and need to be converted into
         --  shared data.

         declare
            Source      : UTF8_In_Place_Data
              with Import, Convention => Ada, Address => Data'Address;
            Destination : constant UTF8_String_Data_Access :=
              Allocate
                (VSS.Unicode.UTF8_Code_Unit_Count (Data.Capacity * 4),
                 VSS.Unicode.UTF8_Code_Unit_Count (Source.Size) + L);

         begin
            Destination.Storage
              (0 .. VSS.Unicode.UTF8_Code_Unit_Count (Source.Size)) :=
                Source.Storage
                  (0 .. VSS.Unicode.UTF8_Code_Unit_Count (Source.Size));
            Destination.Size := VSS.Unicode.UTF8_Code_Unit_Count (Source.Size);
            Destination.Length :=
              VSS.Implementation.Strings.Character_Count (Source.Length);

            Destination.Storage (Destination.Size) := U1;

            if L >= 2 then
               Destination.Storage (Destination.Size + 1) := U2;

               if L >= 3 then
                  Destination.Storage (Destination.Size + 2) := U3;

                  if L = 4 then
                     Destination.Storage (Destination.Size + 3) := U4;
                  end if;
               end if;
            end if;

            Destination.Size := Destination.Size + L;
            Destination.Length := Destination.Length + 1;
            Destination.Storage (Destination.Size) := 16#00#;

            Data :=
              (In_Place => False,
               Capacity => Data.Capacity,
               Padding  => False,
               Handler  => Global_UTF8_String_Handler'Access,
               Pointer  => Destination.all'Address);
         end;
      end if;
   end Append;

   --------------
   -- Backward --
   --------------

   overriding function Backward
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      if Source = null or else Position.Index = 0 then
         return False;

      else
         Unchecked_Backward (Source.Storage, Position);
      end if;

      return Position.Index > 0;
   end Backward;

   --------------
   -- Backward --
   --------------

   overriding function Backward
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : constant UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      if Position.Index = 0 then
         return False;

      else
         Unchecked_Backward (Source.Storage, Position);
      end if;

      return Position.Index > 0;
   end Backward;

   ----------------------------
   -- Before_First_Character --
   ----------------------------

   overriding procedure Before_First_Character
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) is
   begin
      Position := (Index => 0, UTF8_Offset => 0, UTF16_Offset => 0);
   end Before_First_Character;

   ----------------------------
   -- Before_First_Character --
   ----------------------------

   overriding procedure Before_First_Character
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) is
   begin
      Position := (Index => 0, UTF8_Offset => 0, UTF16_Offset => 0);
   end Before_First_Character;

   -------------
   -- Element --
   -------------

   overriding function Element
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : VSS.Implementation.Strings.Cursor)
      return VSS.Unicode.Code_Point
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      if Source = null
        or else Position.Index < 1
        or else Position.Index > Source.Length
      then
         return 16#00_0000#;
      end if;

      return Unchecked_Decode (Source.Storage, Position.UTF8_Offset);
   end Element;

   -------------
   -- Element --
   -------------

   overriding function Element
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : VSS.Implementation.Strings.Cursor)
      return VSS.Unicode.Code_Point
   is
      Source : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      --  raise Program_Error;

      if Position.Index < 1
        or else Position.Index
                  > VSS.Implementation.Strings.Character_Count (Source.Length)
      then
         return 16#00_0000#;
      end if;

      return Unchecked_Decode (Source.Storage, Position.UTF8_Offset);
   end Element;

   -------------
   -- Forward --
   -------------

   overriding function Forward
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      if Source = null or else Position.Index > Source.Length then
         return False;

      elsif Position.Index = 0 then
         Position.Index := 1;

      else
         Unchecked_Forward (Source.Storage, Position);
      end if;

      return Position.Index <= Source.Length;
   end Forward;

   -------------
   -- Forward --
   -------------

   overriding function Forward
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : in out VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : constant UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      if Position.Index
           > VSS.Implementation.Strings.Character_Count (Source.Length)
      then
         return False;

      elsif Position.Index = 0 then
         Position.Index := 1;

      else
         Unchecked_Forward (Source.Storage, Position);
      end if;

      return
        Position.Index
          <= VSS.Implementation.Strings.Character_Count (Source.Length);
   end Forward;

   -----------------------
   -- From_UTF_8_String --
   -----------------------

   overriding procedure From_UTF_8_String
     (Self    : in out UTF8_String_Handler;
      Item    : Ada.Strings.UTF_Encoding.UTF_8_String;
      Data    : out VSS.Implementation.Strings.String_Data;
      Success : out Boolean) is
   begin
      Data :=
        (In_Place => False,
         Padding  => False,
         Capacity => 0,
         Handler  => Self'Unchecked_Access,
         Pointer  => System.Null_Address);
      --  Initialize data.

      if Item'Length = 0 then
         --  Success := True;
         --
         --  return;
         raise Program_Error;
      end if;

      declare
         Destination : UTF8_String_Data_Access
           with Import, Convention => Ada, Address => Data.Pointer'Address;
         Length      : VSS.Implementation.Strings.Character_Count := 0;

      begin
         Destination :=
           Allocate (0, VSS.Unicode.UTF8_Code_Unit_Count (Item'Length));

         Validate_And_Copy (Item, Destination.Storage, Length, Success);

         if Success then
            Destination.Storage
              (VSS.Unicode.UTF8_Code_Unit_Count (Item'Length)) := 16#00#;
            Destination.Size := Item'Length;
            Destination.Length := Length;

         else
            Self.Unreference (Data);
         end if;
      end;
   end From_UTF_8_String;

   -----------------------
   -- From_UTF_8_String --
   -----------------------

   overriding procedure From_UTF_8_String
     (Self    : in out UTF8_In_Place_String_Handler;
      Item    : Ada.Strings.UTF_Encoding.UTF_8_String;
      Data    : out VSS.Implementation.Strings.String_Data;
      Success : out Boolean) is
   begin
      Data :=
        (In_Place => True,
         Padding  => False,
         Capacity => 0,
         Storage  => <>);
      --  Initialize data.

      declare
         Destination : UTF8_In_Place_Data
           with Import, Convention => Ada, Address => Data.Storage'Address;
         Length      : VSS.Implementation.Strings.Character_Count;

      begin
         if Item'Length >= Destination.Storage'Length then
            --  There is not enoght space to store data

            Success := False;

            return;
         end if;

         Validate_And_Copy (Item, Destination.Storage, Length, Success);

         if Success then
            Destination.Storage
              (VSS.Unicode.UTF8_Code_Unit_Count (Item'Length)) := 16#00#;
            Destination.Size := Item'Length;
            Destination.Length := Interfaces.Unsigned_8 (Length);
         end if;
      end;
   end From_UTF_8_String;

   ---------------------------
   -- From_Wide_Wide_String --
   ---------------------------

   overriding procedure From_Wide_Wide_String
     (Self    : in out UTF8_String_Handler;
      Item    : Wide_Wide_String;
      Data    : out VSS.Implementation.Strings.String_Data;
      Success : out Boolean)
   is
      use type VSS.Unicode.Code_Point;

   begin
      Data :=
        (In_Place => False,
         Padding  => False,
         Capacity => 0,
         Handler  => Self'Unchecked_Access,
         Pointer  => System.Null_Address);
      --  Initialize data.

      Success := True;

      if Item'Length = 0 then
         --  Success := True;
         --
         --  return;
         raise Program_Error;
      end if;

      declare
         Destination : UTF8_String_Data_Access
           with Import, Convention => Ada, Address => Data.Pointer'Address;
         Code        : VSS.Unicode.Code_Point;
         L           : VSS.Implementation.UTF8_Encoding.UTF8_Sequence_Length;
         U1          : VSS.Unicode.UTF8_Code_Unit;
         U2          : VSS.Unicode.UTF8_Code_Unit;
         U3          : VSS.Unicode.UTF8_Code_Unit;
         U4          : VSS.Unicode.UTF8_Code_Unit;

      begin
         Destination :=
           Allocate (0, VSS.Unicode.UTF8_Code_Unit_Count (Item'Length));

         for C of Item loop
            if Wide_Wide_Character'Pos (C) not in VSS.Unicode.Code_Point
              or else Wide_Wide_Character'Pos (C) in 16#D800# .. 16#DFFF#
            then
               Success := False;

               exit;

            else
               Code := Wide_Wide_Character'Pos (C);
            end if;

            VSS.Implementation.UTF8_Encoding.Encode (Code, L, U1, U2, U3, U4);

            if Destination.Bulk < Destination.Size + L then
               --  There is no enough storage to store character, reallocate
               --  memory.

               Reallocate
                 (Destination,
                  VSS.Unicode.UTF8_Code_Unit_Count (Data.Capacity) * 4,
                  Destination.Size + L);
            end if;

            Destination.Storage (Destination.Size) := U1;

            if L >= 2 then
               Destination.Storage (Destination.Size + 1) := U2;

               if L >= 3 then
                  Destination.Storage (Destination.Size + 2) := U3;

                  if L = 4 then
                     Destination.Storage (Destination.Size + 3) := U4;
                  end if;
               end if;
            end if;

            Destination.Size := Destination.Size + L;
         end loop;

         if Success then
            Destination.Storage (Destination.Size) := 16#00#;
            Destination.Length := Item'Length;

         else
            Self.Unreference (Data);
         end if;
      end;
   end From_Wide_Wide_String;

   ---------------------------
   -- From_Wide_Wide_String --
   ---------------------------

   overriding procedure From_Wide_Wide_String
     (Self    : in out UTF8_In_Place_String_Handler;
      Item    : Wide_Wide_String;
      Data    : out VSS.Implementation.Strings.String_Data;
      Success : out Boolean)
   is
      use type Interfaces.Unsigned_8;
      use type VSS.Unicode.Code_Point;

   begin
      Data :=
        (In_Place => True,
         Padding  => False,
         Capacity => 0,
         Storage  => <>);
      --  Initialize data.

      Success := True;

      declare
         Destination : UTF8_In_Place_Data
           with Import, Convention => Ada, Address => Data.Storage'Address;
         Code        : VSS.Unicode.Code_Point;
         L           : VSS.Implementation.UTF8_Encoding.UTF8_Sequence_Length;
         U1          : VSS.Unicode.UTF8_Code_Unit;
         U2          : VSS.Unicode.UTF8_Code_Unit;
         U3          : VSS.Unicode.UTF8_Code_Unit;
         U4          : VSS.Unicode.UTF8_Code_Unit;

      begin
         Destination.Size := 0;

         for C of Item loop
            if Wide_Wide_Character'Pos (C) not in VSS.Unicode.Code_Point
              or else Wide_Wide_Character'Pos (C) in 16#D800# .. 16#DFFF#
            then
               Success := False;

               exit;

            else
               Code := Wide_Wide_Character'Pos (C);
            end if;

            VSS.Implementation.UTF8_Encoding.Encode (Code, L, U1, U2, U3, U4);

            if Destination.Storage'Last
              < VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size) + L
            then
               Success := False;

               exit;
            end if;

            Destination.Storage
              (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)) :=
                U1;

            if L >= 2 then
               Destination.Storage
                 (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size) + 1) :=
                   U2;

               if L >= 3 then
                  Destination.Storage
                    (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)
                     + 2) :=
                    U3;

                  if L = 4 then
                     Destination.Storage
                       (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)
                        + 3) :=
                       U4;
                  end if;
               end if;
            end if;

            Destination.Size := Destination.Size + Interfaces.Unsigned_8 (L);
         end loop;

         if Success then
            Destination.Length := Item'Length;
            Destination.Storage
              (VSS.Unicode.UTF8_Code_Unit_Count (Destination.Size)) := 16#00#;
         end if;
      end;
   end From_Wide_Wide_String;

   -------------------
   -- Has_Character --
   -------------------

   overriding function Has_Character
     (Self     : UTF8_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      return
        Source /= null
          and then Position.Index > 0
          and then Position.Index <= Source.Length;
   end Has_Character;

   -------------------
   -- Has_Character --
   -------------------

   overriding function Has_Character
     (Self     : UTF8_In_Place_String_Handler;
      Data     : VSS.Implementation.Strings.String_Data;
      Position : VSS.Implementation.Strings.Cursor) return Boolean
   is
      Source : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      return
        Position.Index > 0
          and then Position.Index
            <= VSS.Implementation.Strings.Character_Count (Source.Length);
   end Has_Character;

   --------------
   -- Is_Empty --
   --------------

   overriding function Is_Empty
     (Self : UTF8_String_Handler;
      Data : VSS.Implementation.Strings.String_Data) return Boolean
   is
      Destination : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      return Destination = null or else Destination.Length = 0;
   end Is_Empty;

   --------------
   -- Is_Empty --
   --------------

   overriding function Is_Empty
     (Self : UTF8_In_Place_String_Handler;
      Data : VSS.Implementation.Strings.String_Data) return Boolean
   is
      use type Interfaces.Unsigned_8;

      Destination : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      return Destination.Length = 0;
   end Is_Empty;

   ------------
   -- Length --
   ------------

   overriding function Length
     (Self : UTF8_String_Handler;
      Data : VSS.Implementation.Strings.String_Data)
      return VSS.Implementation.Strings.Character_Count
   is
      Source : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      return (if Source = null then 0 else Source.Length);
   end Length;

   ------------
   -- Length --
   ------------

   overriding function Length
     (Self : UTF8_In_Place_String_Handler;
      Data : VSS.Implementation.Strings.String_Data)
      return VSS.Implementation.Strings.Character_Count
   is
      Source : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      return VSS.Implementation.Strings.Character_Count (Source.Length);
   end Length;

   ----------------
   -- Reallocate --
   ----------------

   procedure Reallocate
     (Data     : in out UTF8_String_Data_Access;
      Capacity : VSS.Unicode.UTF8_Code_Unit_Count;
      Size     : VSS.Unicode.UTF8_Code_Unit_Count)
   is
      Minimal_Capacity : constant VSS.Unicode.UTF8_Code_Unit_Count :=
        (if Capacity >= Size
         then Capacity
         else (if Data = null
               then Size
               else (if Data.Bulk > Size
                     then Size
                     else Size + Size / Growth_Factor)));

      Aux : UTF8_String_Data_Access := Data;

   begin
      Data := Allocate (0, Minimal_Capacity);

      if Aux /= null then
         declare
            Last : constant VSS.Unicode.UTF8_Code_Unit_Count :=
              VSS.Unicode.UTF8_Code_Unit_Count'Min (Data.Bulk, Aux.Bulk);

         begin
            Data.Storage (0 .. Last) := Aux.Storage (0 .. Last);
            Data.Size := Aux.Size;
            Data.Length := Aux.Length;
            Unreference (Aux);
         end;
      end if;
   end Reallocate;

   ---------------
   -- Reference --
   ---------------

   overriding procedure Reference
     (Self : UTF8_String_Handler;
      Data : in out VSS.Implementation.Strings.String_Data)
   is
      Destination : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      if Destination /= null then
         System.Atomic_Counters.Increment (Destination.Counter);
      end if;
   end Reference;

   -----------------
   -- Split_Lines --
   -----------------

   overriding procedure Split_Lines
     (Self            : UTF8_String_Handler;
      Data            : VSS.Implementation.Strings.String_Data;
      Terminators     : VSS.Strings.Line_Terminator_Set;
      Keep_Terminator : Boolean;
      Lines           : in out
        VSS.Implementation.String_Vectors.String_Vector_Data_Access)
   is
      Source : constant UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      Split_Lines_Common
        (Handler         => Self,
         Data            => Data,
         Storage         => Source.Storage,
         Terminators     => Terminators,
         Keep_Terminator => Keep_Terminator,
         Lines           => Lines);
   end Split_Lines;

   -----------------
   -- Split_Lines --
   -----------------

   overriding procedure Split_Lines
     (Self            : UTF8_In_Place_String_Handler;
      Data            : VSS.Implementation.Strings.String_Data;
      Terminators     : VSS.Strings.Line_Terminator_Set;
      Keep_Terminator : Boolean;
      Lines           : in out
        VSS.Implementation.String_Vectors.String_Vector_Data_Access)
   is
      Source : constant UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      Split_Lines_Common
        (Handler         => Self,
         Data            => Data,
         Storage         => Source.Storage,
         Terminators     => Terminators,
         Keep_Terminator => Keep_Terminator,
         Lines           => Lines);
   end Split_Lines;

   ------------------------
   -- Split_Lines_Common --
   ------------------------

   procedure Split_Lines_Common
     (Handler         :
        VSS.Implementation.String_Handlers.Abstract_String_Handler'Class;
      Data            : VSS.Implementation.Strings.String_Data;
      Storage         : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Terminators     : VSS.Strings.Line_Terminator_Set;
      Keep_Terminator : Boolean;
      Lines           : in out
        VSS.Implementation.String_Vectors.String_Vector_Data_Access)
   is
      procedure Append
        (Source_Storage :
           VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
         First          : VSS.Implementation.Strings.Cursor;
         After_Last     : VSS.Implementation.Strings.Cursor);

      ------------
      -- Append --
      ------------

      procedure Append
        (Source_Storage :
           VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
         First          : VSS.Implementation.Strings.Cursor;
         After_Last     : VSS.Implementation.Strings.Cursor)
      is
         Size : constant VSS.Unicode.UTF8_Code_Unit_Count :=
           After_Last.UTF8_Offset - First.UTF8_Offset;
         Data : VSS.Implementation.Strings.String_Data;

      begin
         if Size = 0 then
            Data :=
              (In_Place => False,
               Padding  => False,
               Capacity => 0,
               Handler  => null,
               Pointer  => System.Null_Address);

         elsif Size <= In_Place_Storage_Capacity
           and then
             VSS.Implementation.String_Configuration.In_Place_Handler.all
               in UTF8_In_Place_String_Handler
         then
            --  Inplace handler is known, use it for short strings.

            Data :=
              (In_Place => True,
               Padding  => False,
               Capacity => 0,
               Storage  => <>);

            declare
               Destination : UTF8_In_Place_Data
                 with Import,
                      Convention => Ada,
                      Address    => Data.Storage'Address;

            begin
               Destination.Storage (0 .. Size - 1) :=
                 Source_Storage
                   (First.UTF8_Offset .. After_Last.UTF8_Offset - 1);
               Destination.Storage (Size) := 0;
               Destination.Size := Interfaces.Unsigned_8 (Size);
               Destination.Length :=
                 Interfaces.Unsigned_8 (After_Last.Index - First.Index);
            end;

         else
            Data :=
              (In_Place => False,
               Padding  => False,
               Capacity => 0,
               Handler  => Global_UTF8_String_Handler'Unrestricted_Access,
               Pointer  => System.Null_Address);

            declare
               Destination : UTF8_String_Data_Access
                 with Import,
                      Convention => Ada,
                      Address    => Data.Pointer'Address;

            begin
               Destination := Allocate (0, Size);

               Destination.Storage (0 .. Size - 1) :=
                 Source_Storage
                   (First.UTF8_Offset .. After_Last.UTF8_Offset - 1);
               Destination.Storage (Size) := 0;
               Destination.Size := Size;
               Destination.Length := After_Last.Index - First.Index;
            end;
         end if;

         VSS.Implementation.String_Vectors.Append_And_Move_Ownership
           (Lines, Data);
      end Append;

      At_First   : VSS.Implementation.Strings.Cursor;
      After_Last : VSS.Implementation.Strings.Cursor;
      Current    : VSS.Implementation.Strings.Cursor;
      CR_Found   : Boolean := False;
      Line_Found : Boolean := False;
      Set_First  : Boolean := True;

   begin
      VSS.Implementation.String_Vectors.Unreference (Lines);

      Handler.Before_First_Character (Data, Current);

      while Handler.Forward (Data, Current) loop
         declare
            use type VSS.Unicode.Code_Point;

            C : constant VSS.Unicode.Code_Point :=
              Handler.Element (Data, Current);

         begin
            if CR_Found then
               if C /= Line_Feed and Terminators (VSS.Strings.CR) then
                  --  It is special case to handle single CR when both CR and
                  --  CRLF are allowed.

                  CR_Found  := False;
                  Set_First := True;

                  if Keep_Terminator then
                     After_Last := Current;
                  end if;

                  Append (Storage, At_First, After_Last);
               end if;
            end if;

            if Set_First then
               Set_First := False;
               At_First  := Current;
            end if;

            case C is
               when Line_Feed =>
                  if Terminators (VSS.Strings.CRLF) and CR_Found then
                     if Keep_Terminator then
                        --  Update After_Last position to point to current
                        --  character to preserve it.

                        After_Last := Current;
                     end if;

                     CR_Found   := False;
                     Line_Found := True;

                  elsif Terminators (VSS.Strings.LF) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Line_Tabulation =>
                  if Terminators (VSS.Strings.VT) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Form_Feed =>
                  if Terminators (VSS.Strings.FF) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Carriage_Return =>
                  if Terminators (VSS.Strings.CRLF) then
                     After_Last := Current;
                     CR_Found   := True;

                  elsif Terminators (VSS.Strings.CR) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Next_Line =>
                  if Terminators (VSS.Strings.NEL) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Line_Separator =>
                  if Terminators (VSS.Strings.LS) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when Paragraph_Separator =>
                  if Terminators (VSS.Strings.PS) then
                     After_Last := Current;
                     Line_Found := True;
                  end if;

               when others =>
                  null;
            end case;

            if Line_Found then
               Line_Found := False;
               Set_First  := True;

               if Keep_Terminator then
                  declare
                     Dummy : constant Boolean :=
                       Handler.Forward (Data, After_Last);

                  begin
                     null;
                  end;
               end if;

               Append (Storage, At_First, After_Last);
            end if;
         end;
      end loop;

      if CR_Found then
         VSS.Implementation.String_Vectors.Append_And_Move_Ownership
           (Lines, VSS.Implementation.Strings.Null_String_Data);

      elsif not Set_First then
         Append (Storage, At_First, Current);
      end if;
   end Split_Lines_Common;

   ---------------------
   -- To_UTF_8_String --
   ---------------------

   overriding function To_UTF_8_String
     (Self : UTF8_String_Handler;
      Data : VSS.Implementation.Strings.String_Data)
      return Ada.Strings.UTF_Encoding.UTF_8_String
   is
      Destination : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      return Result : Ada.Strings.UTF_Encoding.UTF_8_String
        (1 .. (if Destination = null then 0 else Natural (Destination.Size)))
      do
         for J in Result'Range loop
            Result (J) :=
              Standard.Character'Val
                (Destination.Storage
                   (VSS.Unicode.UTF8_Code_Unit_Count (J - 1)));
         end loop;
      end return;
   end To_UTF_8_String;

   ---------------------
   -- To_UTF_8_String --
   ---------------------

   overriding function To_UTF_8_String
     (Self : UTF8_In_Place_String_Handler;
      Data : VSS.Implementation.Strings.String_Data)
      return Ada.Strings.UTF_Encoding.UTF_8_String
   is
      Destination : UTF8_In_Place_Data
        with Import, Convention => Ada, Address => Data'Address;

   begin
      return Result : Ada.Strings.UTF_Encoding.UTF_8_String
                        (1 .. Natural (Destination.Size))
      do
         for J in Result'Range loop
            Result (J) :=
              Standard.Character'Val
                (Destination.Storage
                   (VSS.Unicode.UTF8_Code_Unit_Count (J - 1)));
         end loop;
      end return;
   end To_UTF_8_String;

   -----------------------
   -- Unchecked_Backward --
   -----------------------

   procedure Unchecked_Backward
     (Storage  : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Position : in out VSS.Implementation.Strings.Cursor)
   is
      use type VSS.Unicode.UTF16_Code_Unit_Count;

   begin
      Position.UTF8_Offset  := Position.UTF8_Offset - 1;
      Position.Index := Position.Index - 1;

      loop
         declare
            Code : constant VSS.Unicode.UTF8_Code_Unit :=
              Storage (Position.UTF8_Offset);
         begin
            case Code is
               when 16#80# .. 16#BF# =>
                  Position.UTF8_Offset  := Position.UTF8_Offset - 1;

               when 16#00# .. 16#7F#
                  | 16#C2# .. 16#DF#
                  | 16#E0# .. 16#EF# =>

                  Position.UTF16_Offset := Position.UTF16_Offset - 1;
                  exit;

               when 16#F0# .. 16#F4# =>
                  Position.UTF16_Offset := Position.UTF16_Offset - 2;
                  exit;

               when others =>
                  raise Program_Error with "string data is corrupted";
            end case;
         end;
      end loop;
   end Unchecked_Backward;

   ----------------------
   -- Unchecked_Decode --
   ----------------------

   function Unchecked_Decode
     (Storage : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Offset  : VSS.Unicode.UTF8_Code_Unit_Index)
      return VSS.Unicode.Code_Point
   is
      use type VSS.Unicode.Code_Point;
      use type VSS.Unicode.UTF8_Code_Unit;

      U1 : VSS.Unicode.Code_Point := VSS.Unicode.Code_Point (Storage (Offset));
      U2 : VSS.Unicode.Code_Point;
      U3 : VSS.Unicode.Code_Point;
      U4 : VSS.Unicode.Code_Point;

   begin
      case U1 is
         when 16#00# .. 16#7F# =>
            --  1x code units sequence

            return U1;

         when 16#C2# .. 16#DF# =>
            --  2x code units sequence

            U1 := (U1 and 2#0001_1111#) * 2#0100_0000#;
            U2 :=
              VSS.Unicode.Code_Point (Storage (Offset + 1) and 2#0011_1111#);

            return U1 or U2;

         when 16#E0# .. 16#EF# =>
            --  3x code units sequence

            U1 := (U1 and 2#0000_1111#) * 2#01_0000_0000_0000#;
            U2 := VSS.Unicode.Code_Point
              (Storage (Offset + 1) and 2#0011_1111#) * 2#0100_0000#;
            U3 :=
              VSS.Unicode.Code_Point (Storage (Offset + 2) and 2#0011_1111#);

            return U1 or U2 or U3;

         when 16#F0# .. 16#F4# =>
            --  4x code units sequence

            U1 := (U1 and 2#0000_0111#) * 2#0100_0000_0000_0000_0000#;
            U2 := VSS.Unicode.Code_Point
              (Storage (Offset + 1) and 2#0011_1111#) * 2#010_000_0000_0000#;
            U3 :=
              VSS.Unicode.Code_Point
                (Storage (Offset + 2) and 2#0011_1111#) * 2#0100_0000#;
            U4 :=
              VSS.Unicode.Code_Point (Storage (Offset + 3) and 2#0011_1111#);

            return U1 or U2 or U3 or U4;

         when others =>
            raise Program_Error;
      end case;
   end Unchecked_Decode;

   -----------------------
   -- Unchecked_Forward --
   -----------------------

   procedure Unchecked_Forward
     (Storage  : VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Position : in out VSS.Implementation.Strings.Cursor)
   is
      use type VSS.Unicode.UTF16_Code_Unit_Count;

      Code : constant VSS.Unicode.UTF8_Code_Unit :=
        Storage (Position.UTF8_Offset);

   begin
      Position.Index := Position.Index + 1;

      case Code is
         when 16#00# .. 16#7F# =>
            Position.UTF8_Offset  := Position.UTF8_Offset + 1;
            Position.UTF16_Offset := Position.UTF16_Offset + 1;

         when 16#C2# .. 16#DF# =>
            Position.UTF8_Offset  := Position.UTF8_Offset + 2;
            Position.UTF16_Offset := Position.UTF16_Offset + 1;

         when 16#E0# .. 16#EF# =>
            Position.UTF8_Offset  := Position.UTF8_Offset + 3;
            Position.UTF16_Offset := Position.UTF16_Offset + 1;

         when 16#F0# .. 16#F4# =>
            Position.UTF8_Offset  := Position.UTF8_Offset + 4;
            Position.UTF16_Offset := Position.UTF16_Offset + 2;

         when others =>
            raise Program_Error with "string data is corrupted";
      end case;

      --  XXX case statement above may be rewritten as below to avoid
      --  use of branch instructions.
      --
      --  Position.UTF8_Offset  :=
      --    Position.UTF8_Offset + 1
      --      + (if (Code and 2#1000_0000#) = 2#1000_0000# then 1 else 0)
      --      + (if (Code and 2#1110_0000#) = 2#1110_0000# then 1 else 0)
      --      + (if (Code and 2#1111_0000#) = 2#1111_0000# then 1 else 0);
      --
      --  Position.UTF16_Offset :=
      --    Position.UTF16_Offset + 1
      --      + (if (Code and 2#1111_0000#) = 2#1111_0000# then 1 else 0);
   end Unchecked_Forward;

   -----------------
   -- Unreference --
   -----------------

   procedure Unreference (Data : in out UTF8_String_Data_Access) is
      procedure Free is
        new Ada.Unchecked_Deallocation
              (UTF8_String_Data, UTF8_String_Data_Access);

   begin
      if Data /= null then
         if System.Atomic_Counters.Decrement (Data.Counter) then
            Free (Data);

         else
            Data := null;
         end if;
      end if;
   end Unreference;

   -----------------
   -- Unreference --
   -----------------

   overriding procedure Unreference
     (Self : UTF8_String_Handler;
      Data : in out VSS.Implementation.Strings.String_Data)
   is
      Destination : UTF8_String_Data_Access
        with Import, Convention => Ada, Address => Data.Pointer'Address;

   begin
      Unreference (Destination);
   end Unreference;

   -----------------------
   -- Validate_And_Copy --
   -----------------------

   procedure Validate_And_Copy
     (Source      : Ada.Strings.UTF_Encoding.UTF_8_String;
      Destination : out VSS.Implementation.UTF8_Encoding.UTF8_Code_Unit_Array;
      Length      : out VSS.Implementation.Strings.Character_Count;
      Success     : out Boolean)
   is
      State : Verification_State := Initial;
      Code  : VSS.Unicode.UTF8_Code_Unit;

   begin
      Length := 0;

      for J in Source'Range loop
         Code := Standard.Character'Pos (Source (J));

         case State is
            when Initial =>
               Length := Length + 1;

               case Code is
                  when 16#00# .. 16#7F# =>
                     null;

                  when 16#C2# .. 16#DF# =>
                     State := UT1;

                  when 16#E0# =>
                     State := U31;

                  when 16#E1# .. 16#EC# =>
                     State := UT2;

                  when 16#ED# =>
                     State := U33;

                  when 16#EE# .. 16#EF# =>
                     State := UT2;

                  when 16#F0# =>
                     State := U41;

                  when 16#F1# .. 16#F3# =>
                     State := UT3;

                  when 16#F4# =>
                     State := U43;

                  when others =>
                     State := Ill_Formed;
               end case;

            when U31 =>
               case Code is
                  when 16#A0# .. 16#BF# =>
                     State := UT1;

                  when others =>
                     State := Ill_Formed;
               end case;

            when U33 =>
               case Code is
                  when 16#80# .. 16#9F# =>
                     State := UT1;

                  when others =>
                     State := Ill_Formed;
               end case;

            when U41 =>
               case Code is
                  when 16#90# .. 16#BF# =>
                     State := UT2;

                  when others =>
                     State := Ill_Formed;
               end case;

            when U43 =>
               case Code is
                  when 16#80# .. 16#8F# =>
                     State := UT2;

                  when others =>
                     State := Ill_Formed;
               end case;

            when UT1 =>
               case Code is
                  when 16#80# .. 16#BF# =>
                     State := Initial;

                  when others =>
                     State := Ill_Formed;
               end case;

            when UT2 =>
               case Code is
                  when 16#80# .. 16#BF# =>
                     State := UT1;

                  when others =>
                     State := Ill_Formed;
               end case;

            when UT3 =>
               case Code is
                  when 16#80# .. 16#BF# =>
                     State := UT2;

                  when others =>
                     State := Ill_Formed;
               end case;

            when Ill_Formed =>
               exit;
         end case;

         Destination
           (VSS.Unicode.UTF8_Code_Unit_Count (J - Source'First)) := Code;
      end loop;

      Success := State = Initial;
   end Validate_And_Copy;

end VSS.Implementation.UTF8_String_Handlers;
