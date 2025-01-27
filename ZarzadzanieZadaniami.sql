-- Struktura bazy danych dla systemu zarządzania zadaniami

-- Włączanie Snapshot Isolation
USE [Database];
GO
-- Włączenie trybu Snapshot Isolation zapewnia, że transakcje mogą działać równolegle bez blokowania się nawzajem, dzięki wykorzystaniu wersjonowania danych. Jest to szczególnie przydatne w systemach z dużą liczbą odczytów i zapisów, takich jak system zarządzania zadaniami.
ALTER DATABASE [Database] SET ALLOW_SNAPSHOT_ISOLATION ON;
GO
ALTER DATABASE [Database] SET READ_COMMITTED_SNAPSHOT ON;
GO

-- Sprawdzanie włączenia Snapshot Isolation
SELECT 
    name AS DatabaseName,
    snapshot_isolation_state_desc AS SnapshotIsolation,
    is_read_committed_snapshot_on AS ReadCommittedSnapshot
FROM sys.databases
WHERE name = 'Database';

-- Tabela dla podmiotów
CREATE TABLE Tenants (
    TenantId INT IDENTITY PRIMARY KEY,
    TenantName NVARCHAR(255) NOT NULL
);

-- Tabela dla użytkowników
CREATE TABLE Users (
    UserId INT IDENTITY PRIMARY KEY,
    TenantId INT NOT NULL FOREIGN KEY REFERENCES Tenants(TenantId),
    UserName NVARCHAR(255) NOT NULL,
    Role NVARCHAR(50) CHECK (Role IN ('Employee', 'Manager')) NOT NULL
);

-- Tworzenie funkcji partycjonowania
CREATE PARTITION FUNCTION TenantPartitionFunction (INT)
AS RANGE LEFT FOR VALUES (1, 10, 20, 30, 40);
-- Wyjaśnienie: Przyjęte wartości 1, 10, 20 itd. zakładają podział zadań dla podmiotów na różne zakresy identyfikatorów w zależności od ich rosnącej liczby. Pozwala to na lepsze skalowanie systemu w architekturze multitenant.

-- Tworzenie schematu partycjonowania
CREATE PARTITION SCHEME TenantPartitionScheme
AS PARTITION TenantPartitionFunction
ALL TO ([PRIMARY]);

-- Tabela dla zadań
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
)
ON TenantPartitionScheme (TenantId);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ArchivedTasks' AND type = 'U')
BEGIN
    CREATE TABLE ArchivedTasks (
        TaskID INT PRIMARY KEY,           -- Zakładam, że TaskID jest kluczem głównym
        TaskName NVARCHAR(255) NOT NULL,
        CreatedDate DATETIME NOT NULL,
        DueDate DATETIME NULL,
        Status NVARCHAR(50) NOT NULL,
        ArchivedDate DATETIME DEFAULT GETDATE() -- Pole informujące o dacie archiwizacji
    );
END

-- Tabela dla historii zmian zadań
CREATE TABLE TaskHistory (
    HistoryId BIGINT IDENTITY PRIMARY KEY,
    TaskId BIGINT NOT NULL FOREIGN KEY REFERENCES Tasks(TaskId),
    ChangeDate DATETIME NOT NULL DEFAULT GETDATE(),
    ChangedBy INT NOT NULL FOREIGN KEY REFERENCES Users(UserId),
    ChangeDescription NVARCHAR(MAX) NOT NULL
);

-- Kompresja dla indexu na tabeli TaskHistory

CREATE INDEX IX_TaskHistory_TaskID ON TaskHistory (taskid)
WITH (DATA_COMPRESSION = PAGE);

-- Tabela dla uprawnień
CREATE TABLE Permissions (
    PermissionId INT IDENTITY PRIMARY KEY,
    TaskId BIGINT NOT NULL FOREIGN KEY REFERENCES Tasks(TaskId),
    SharedWith INT NOT NULL FOREIGN KEY REFERENCES Users(UserId)
);

-- Procedura: Dodawanie zadania
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
            WHERE TenantId = @TenantId AND OwnerId = @OwnerId AND Title = @Title AND Description = @Description
        )
        BEGIN
            RAISERROR('A task with similar attributes already exists.', 16, 1);
            RETURN;
        END;

        INSERT INTO Tasks (TenantId, OwnerId, Title, Priority, Description, Status)
        VALUES (@TenantId, @OwnerId, @Title, @Priority, @Description, @Status);
    END TRY
    BEGIN CATCH
        -- Obsługa błędów
        THROW;
    END CATCH
END;

-- Procedura: Aktualizacja zadania
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
        DECLARE @OldTitle NVARCHAR(255),
                @OldPriority NVARCHAR(50),
                @OldDescription NVARCHAR(MAX),
                @OldStatus NVARCHAR(50);

        SELECT 
            @OldTitle = Title,
            @OldPriority = Priority,
            @OldDescription = Description,
            @OldStatus = Status
        FROM Tasks
        WHERE TaskId = @TaskId;

        UPDATE Tasks
        SET
            Title = COALESCE(@Title, Title),
            Priority = COALESCE(@Priority, Priority),
            Description = COALESCE(@Description, Description),
            Status = COALESCE(@Status, Status),
            UpdatedAt = GETDATE()
        WHERE TaskId = @TaskId;

        -- Dodanie szczegółów o zaktualizowanych polach do historii
        IF @Title IS NOT NULL AND @Title <> @OldTitle
            INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
            VALUES (@TaskId, @UpdatedBy, 'Title changed from "' + @OldTitle + '" to "' + @Title + '"');

        IF @Priority IS NOT NULL AND @Priority <> @OldPriority
            INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
            VALUES (@TaskId, @UpdatedBy, 'Priority changed from "' + @OldPriority + '" to "' + @Priority + '"');

        IF @Description IS NOT NULL AND @Description <> @OldDescription
            INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
            VALUES (@TaskId, @UpdatedBy, 'Description updated');

        IF @Status IS NOT NULL AND @Status <> @OldStatus
            INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
            VALUES (@TaskId, @UpdatedBy, 'Status changed from "' + @OldStatus + '" to "' + @Status + '"');
    END TRY
    BEGIN CATCH
        -- Obsługa błędów
        THROW;
    END CATCH
END;

--Alternatywnie tworzenie triggera do modyfikaci w tabli Tasks

CREATE TRIGGER trg_AfterTaskUpdate
ON Tasks
AFTER UPDATE
AS
BEGIN
    -- Aktualizujemy kolumnę UpdatedAt w tabeli Tasks
    UPDATE Tasks
    SET UpdatedAt = GETDATE()  -- lub SYSDATETIME() w zależności od potrzeby
    FROM Tasks t
    INNER JOIN inserted i ON t.TaskId = i.TaskId;

    -- Wstawiamy rekord do tabeli TaskHistory
    INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
    SELECT 
        inserted.TaskId,
        SUSER_SNAME(),  -- Użytkownik, który wykonał aktualizację
        'Task updated via direct update'
    FROM inserted;
END;
------------------------------

-- Procedura: Usuwanie zadania
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
        -- Obsługa błędów
        THROW;
    END CATCH
END;

-- Procedura: Przypisywanie uprawnień
CREATE PROCEDURE ShareTask
    @TaskId BIGINT,
    @SharedWith INT
AS
BEGIN
    BEGIN TRY
        IF NOT EXISTS (
            SELECT 1 FROM Permissions WHERE TaskId = @TaskId AND SharedWith = @SharedWith
        )
        BEGIN
            INSERT INTO Permissions (TaskId, SharedWith)
            VALUES (@TaskId, @SharedWith);

            -- Logowanie operacji
            INSERT INTO TaskHistory (TaskId, ChangedBy, ChangeDescription)
            VALUES (@TaskId, @SharedWith, 'Task shared with user ID ' + CAST(@SharedWith AS NVARCHAR));
        END;
    END TRY
    BEGIN CATCH
        -- Obsługa błędów
        THROW;
    END CATCH
END;

-- Procedura: Statystyki dla menadżerów
CREATE PROCEDURE GetManagerStatistics
    @TenantId INT
AS
BEGIN
    SELECT
        u.UserName AS Employee,
        t.Status,
        COUNT(*) AS TaskCount,
        MONTH(t.CreatedAt) AS Month
    FROM Tasks t
    JOIN Users u ON t.OwnerId = u.UserId
    WHERE t.TenantId = @TenantId
    GROUP BY u.UserName, t.Status, MONTH(t.CreatedAt)
    ORDER BY Month, TaskCount DESC;
END;

----------------------------------------------------
EXEC sp_set_session_context 'UserId', @UserId;

CREATE PROCEDURE GetUserTasks
    @UserId INT
AS
BEGIN
    DECLARE @IsManager BIT;
    DECLARE @UserId INT;
    SET @UserId = SESSION_CONTEXT('UserId');
    -- Sprawdzamy, czy użytkownik jest menedżerem
    SELECT @IsManager = CASE WHEN Role = 'Manager' THEN 1 ELSE 0 END
    FROM Users
    WHERE UserId = @UserId;

    IF @IsManager = 1
    BEGIN
        -- Menedżer może widzieć wszystkie zadania
        SELECT TaskId, Title, Description, Status, Priority
        FROM Tasks;
    END
    ELSE
    BEGIN
        -- Zwykły użytkownik widzi tylko swoje zadania lub zadania, które zostały z nim udostępnione
        SELECT t.TaskId, t.Title, t.Description, t.Status, t.Priority
        FROM Tasks t
        LEFT JOIN Permissions p ON t.TaskId = p.TaskId
        WHERE t.OwnerId = @UserId OR p.SharedWith = @UserId;
    END
END;


---------------------------------------------------

-- Procedura: Raport dla podmiotów
CREATE PROCEDURE TenantActivityReport
    @TenantId INT
AS
BEGIN
    SELECT
        t.TenantId,
        COUNT(DISTINCT u.UserId) AS TotalUsers,
        COUNT(t.TaskId) AS TotalTasks,
        SUM(CASE WHEN t.Status = 'Completed' THEN 1 ELSE 0 END) AS CompletedTasks,
        SUM(CASE WHEN t.Status = 'Pending' THEN 1 ELSE 0 END) AS PendingTasks
    FROM Tasks t
    JOIN Users u ON t.OwnerId = u.UserId
    WHERE t.TenantId = @TenantId
    GROUP BY t.TenantId;
END;

-- Procedura: Archiwizacja zadań
CREATE PROCEDURE ArchiveOldTasks
    @CutoffDate DATETIME
AS
BEGIN
    BEGIN TRY
        INSERT INTO ArchivedTasks (TaskId, TenantId, OwnerId, Title, Priority, Description, Status, CreatedAt, UpdatedAt)
        SELECT TaskId, TenantId, OwnerId, Title, Priority, Description, Status, CreatedAt, UpdatedAt
        FROM Tasks
        WHERE UpdatedAt < @CutoffDate;

        DELETE FROM Permissions WHERE TaskId IN (SELECT TaskId FROM Tasks WHERE UpdatedAt < @CutoffDate);
        DELETE FROM TaskHistory WHERE TaskId IN (SELECT TaskId FROM Tasks WHERE UpdatedAt < @CutoffDate);
        DELETE FROM Tasks WHERE UpdatedAt < @CutoffDate;

        -- Dodanie logowania operacji archiwizacji
        PRINT 'Tasks archived successfully.';
    END TRY
     BEGIN CATCH
        ROLLBACK TRANSACTION; -- Wycofanie transakcji w przypadku błędu
        PRINT 'There was an error during archiving: ' + ERROR_MESSAGE();
        THROW;
    END CATCH
END;

-- 3. Testowanie procedury
-- Przykładowe uruchomienie procedury: archiwizujemy dane starsze niż 1 rok
DECLARE @CutoffDate DATETIME = DATEADD(YEAR, -1, GETDATE());
EXEC ArchiveOldTasks @CutoffDate;

-- 4. Sprawdzenie wyników
-- Dane zarchiwizowane
SELECT * FROM ArchivedTasks;
-- Dane pozostałe w tabeli Tasks
SELECT * FROM Tasks;
