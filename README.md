# Dokumentacja techniczna systemu zarządzania zadaniami

## Wprowadzenie

System zarządzania zadaniami to aplikacja oparta na SQL Server, zaprojektowana z myślą o pracy w środowisku wielopodmiotowym (multitenant). System obsługuje funkcjonalności dla pracowników i menedżerów, umożliwiając zarządzanie zadaniami, ich historią oraz statystykami.

---

## Architektura systemu

System bazy danych został zaprojektowany z naciskiem na skalowalność i wydajność. Główne komponenty obejmują:

- **Tabela Tenants:** Zarządzanie podmiotami, które korzystają z systemu.
- **Tabela Users:** Przechowuje dane o użytkownikach i ich rolach (pracownik lub menedżer).
- **Tabela Tasks:** Przechowuje zadania.
- **Tabela TaskHistory:** Rejestruje historię zmian w zadaniach.
- **Tabela Permissions:** Zarządza udostępnianiem zadań.

---

## Wymagania systemowe

- **Serwer bazodanowy:** Microsoft SQL Server (wersja wspierająca partycjonowanie i Snapshot Isolation).
- **Konfiguracja:**
  - Snapshot Isolation włączony dla obsługi transakcji.
  - Indeksowanie na kluczach głównych i polach często wyszukiwanych.

---

## Konfiguracja serwera SQL Server

1. **Włączenie Snapshot Isolation:**

   ```sql
   ALTER DATABASE [Database] SET ALLOW_SNAPSHOT_ISOLATION ON;
   ALTER DATABASE [Database] SET READ_COMMITTED_SNAPSHOT ON;
   ```

   Snapshot Isolation umożliwia lepszą współbieżność transakcji, szczególnie w systemach z dużą liczbą odczytów i zapisów.

2. **Sprawdzenie konfiguracji:**

   ```sql
   SELECT
       name AS DatabaseName,
       snapshot_isolation_state_desc AS SnapshotIsolation,
       is_read_committed_snapshot_on AS ReadCommittedSnapshot
   FROM sys.databases
   WHERE name = 'Database';
   ```

---

## Struktura bazy danych

1. **Tabela Tenants:**

   ```sql
   CREATE TABLE Tenants (
       TenantId INT IDENTITY PRIMARY KEY,
       TenantName NVARCHAR(255) NOT NULL
   );
   ```

2. **Tabela Users:**

   ```sql
   CREATE TABLE Users (
       UserId INT IDENTITY PRIMARY KEY,
       TenantId INT NOT NULL FOREIGN KEY REFERENCES Tenants(TenantId),
       UserName NVARCHAR(255) NOT NULL,
       Role NVARCHAR(50) CHECK (Role IN ('Employee', 'Manager')) NOT NULL
   );
   ```

3. **Tabela Tasks:**

   ```sql
   CREATE TABLE Tasks (
       TaskId BIGINT IDENTITY PRIMARY KEY,
       TenantId INT NOT NULL FOREIGN KEY REFERENCES Tenants(TenantId),
       OwnerId INT NOT NULL FOREIGN KEY REFERENCES Users(UserId),
       Title NVARCHAR(255) NOT NULL,
       Priority NVARCHAR(50) CHECK (Priority IN ('Low', 'Medium', 'High')) NOT NULL,
       Description NVARCHAR(MAX),
       Status NVARCHAR(50) CHECK (Status IN ('Pending', 'InProgress', 'Completed')) NOT NULL,
       CreatedAt DATETIME NOT NULL DEFAULT GETDATE(),
       UpdatedAt DATETIME NOT NULL DEFAULT GETDATE()
   );
   ```

4. **Tabela TaskHistory:**

   ```sql
   CREATE TABLE TaskHistory (
       HistoryId BIGINT IDENTITY PRIMARY KEY,
       TaskId BIGINT NOT NULL FOREIGN KEY REFERENCES Tasks(TaskId),
       ChangeDate DATETIME NOT NULL DEFAULT GETDATE(),
       ChangedBy INT NOT NULL FOREIGN KEY REFERENCES Users(UserId),
       ChangeDescription NVARCHAR(MAX) NOT NULL
   );
   ```

5. **Tabela Permissions:**

   ```sql
   CREATE TABLE Permissions (
       PermissionId INT IDENTITY PRIMARY KEY,
       TaskId BIGINT NOT NULL FOREIGN KEY REFERENCES Tasks(TaskId),
       SharedWith INT NOT NULL FOREIGN KEY REFERENCES Users(UserId)
   );
   ```

---

## Procedury składowane

### Dodawanie zadania

```sql
CREATE PROCEDURE AddTask
    @TenantId INT,
    @OwnerId INT,
    @Title NVARCHAR(255),
    @Priority NVARCHAR(50),
    @Description NVARCHAR(MAX),
    @Status NVARCHAR(50)
AS
BEGIN
    BEGIN TRY
        IF EXISTS (
            SELECT 1 FROM Tasks
            WHERE TenantId = @TenantId AND OwnerId = @OwnerId AND Title = @Title
        )
        BEGIN
            RAISERROR('A task with similar attributes already exists.', 16, 1);
            RETURN;
        END;

        INSERT INTO Tasks (TenantId, OwnerId, Title, Priority, Description, Status)
        VALUES (@TenantId, @OwnerId, @Title, @Priority, @Description, @Status);
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
```

### Aktualizacja zadania

```sql
CREATE PROCEDURE UpdateTask
    @TaskId BIGINT,
    @UpdatedBy INT,
    @Title NVARCHAR(255) = NULL,
    @Priority NVARCHAR(50) = NULL,
    @Description NVARCHAR(MAX) = NULL,
    @Status NVARCHAR(50) = NULL
AS
BEGIN
    BEGIN TRY
        UPDATE Tasks
        SET
            Title = COALESCE(@Title, Title),
            Priority = COALESCE(@Priority, Priority),
            Description = COALESCE(@Description, Description),
            Status = COALESCE(@Status, Status),
            UpdatedAt = GETDATE()
        WHERE TaskId = @TaskId;

        INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
        VALUES (@TaskId, @UpdatedBy, 'Task updated');
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
```

### Usuwanie zadania

```sql
CREATE PROCEDURE DeleteTask
    @TaskId BIGINT,
    @DeletedBy INT
AS
BEGIN
    BEGIN TRY
        INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
        VALUES (@TaskId, @DeletedBy, 'Task deleted');

        DELETE FROM Permissions WHERE TaskId = @TaskId;
        DELETE FROM TaskHistory WHERE TaskId = @TaskId;
        DELETE FROM Tasks WHERE TaskId = @TaskId;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
```

---

## Testowe dane

Do generowania danych testowych wykorzystano procedury generujące losowych użytkowników i zadania. Skrypt generuje:

- 100 użytkowników na podmiot.
- 1000 zadań na użytkownika.

---

## Logowanie i monitorowanie

1. **Historia zmian:** Rejestruje wszystkie zmiany w zadaniach.
2. **Logowanie błędów:** Wszystkie błędy są rejestrowane w standardowym logu SQL Server.

---

## Dalsze kroki

1. **Rozbudowa API:** Utworzenie warstwy komunikacyjnej dla aplikacji frontendowej.
2. **Monitorowanie wydajności:** Użycie narzędzi, takich jak SQL Profiler, do analizy zapytań.
